#!/usr/bin/env Rscript
# Fresh-CLI region/junction counts; preparation representations are reported separately.
suppressPackageStartupMessages(library(utils))
threads <- as.integer(Sys.getenv("AIE_BENCH_THREADS", "1"))
stopifnot(threads %in% c(1L, 4L))
Sys.setenv(OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", MKL_NUM_THREADS="1",
           RAYON_NUM_THREADS=as.character(threads))
duckdb <- Sys.getenv("DUCKDB", Sys.which("duckdb"))
aie <- normalizePath(".gravlax/target/release/aie", mustWork=TRUE)
stopifnot(nzchar(duckdb), file.exists("ext/duckhts.duckdb_extension"))
out <- Sys.getenv("AIE_BENCH_OUT", paste0("work/benchmark-t", threads))
if (dir.exists(out)) stop("Use a new AIE_BENCH_OUT directory; existing receipts are preserved")
dir.create(out, recursive=TRUE, showWarnings=FALSE)
out <- normalizePath(out)
fixture <- readLines("work/sample_a.sam")
header <- grep("^@", fixture, value=TRUE)
records <- strsplit(grep("^@", fixture, value=TRUE, invert=TRUE), "\t", fixed=TRUE)
load_sql <- paste(readLines("sql/load.sql"), collapse="\n")
queries <- lapply(c(region="sql/region.sql",junction="sql/junction.sql"), readLines)
rows <- list()

prepare_input <- function(cells, dir) {
  dir.create(file.path(dir,"work"),recursive=TRUE,showWarnings=FALSE)
  codes <- apply(matrix(c("A","C","G","T")[outer(seq_len(cells)-1,4^(15:0),
    function(i,p) floor(i/p)%%4)+1L], nrow=cells),1,paste0,collapse="")
  sam <- file(file.path(dir,"work/sample_a.sam"),"wt")
  on.exit(if (isOpen(sam)) close(sam))
  writeLines(header,sam)
  for (i in seq_len(cells)) for (record in records) {
    record[[1L]] <- paste0(record[[1L]],"_cell",i)
    record[[13L]] <- paste0("CB:Z:",codes[[i]])
    record[[15L]] <- paste0("CR:Z:",codes[[i]])
    writeLines(paste(record,collapse="\t"),sam)
  }
  close(sam)
  on.exit(NULL)
  samtools <- Sys.which("samtools")
  status <- system(sprintf("%s view -bS %s | %s sort -o %s",
    shQuote(samtools),shQuote(file.path(dir,"work/sample_a.sam")),shQuote(samtools),
    shQuote(file.path(dir,"work/sample_a.bam"))))
  stopifnot(status==0L)
  empty <- file.path(dir,"work/empty.sam")
  writeLines(header,empty)
  stopifnot(system2(samtools,c("view","-bS",shQuote(empty),"-o",shQuote(file.path(dir,"work/sample_b.bam"))))==0L)
  writeLines(codes,file.path(dir,"barcodes.txt"))
  cells*length(records)
}

measure <- function(engine,operation,cells,replicate,command,args,dir,output,expected=NULL) {
  slug <- sprintf("%s-%s-n%d-r%d",engine,operation,cells,replicate)
  receipts <- file.path(out, slug)
  dir.create(receipts)
  laps <- list()
  total <- 0
  repeat {
    i <- length(laps)+1L
    log <- file.path(receipts,paste0(i,".log"))
    time <- file.path(receipts,paste0(i,".time"))
    stdout <- file.path(receipts,paste0(i,".out"))
    # Each iteration is a fresh CLI, not a retry or a reused engine connection.
    if (operation=="prepare" && engine=="gravlax") unlink(file.path(dir,sprintf("cohort-r%d.aie",replicate)))
    start <- proc.time()[["elapsed"]]
    status <- system2("/usr/bin/timeout",c("120s","/usr/bin/time","-f",shQuote("%M"),"-o",shQuote(time),
      shQuote(command),args),stdout=stdout,stderr=log)
    elapsed <- proc.time()[["elapsed"]]-start
    rss <- suppressWarnings(as.numeric(tail(readLines(time,warn=FALSE),1L)))*1024
    good <- status==0L && elapsed<=120 && is.finite(rss) && rss<=2*1024^3
    error <- if (good) "" else paste("process/budget failure",status)
    if (any(file.info(c(stdout,log))$size>64*1024^2)) {good<-FALSE;error<-"receipt size exceeded"}
    if (operation=="prepare") {
      prepared <- if (engine=="gravlax") file.path(dir,sprintf("cohort-r%d.aie",replicate)) else
        list.files("work",pattern="\\.parquet$",full.names=TRUE)
      if (sum(file.info(prepared)$size)>2*1024^3) {good<-FALSE;error<-"prepared-output size exceeded"}
    }
    if (good && operation!="prepare") {
      observed <- if (engine=="gravlax") {
        tokens <- strsplit(grep("^cell\t",readLines(stdout),value=TRUE),"\t",fixed=TRUE)
        data.frame(cell=vapply(tokens,`[[`,"",2L),count=as.numeric(vapply(tokens,`[[`,"",3L)))
      } else {
        data <- read.csv(stdout,colClasses=c("character","character","numeric"))
        data.frame(cell=data[[2L]],count=data[[3L]])
      }
      observed <- observed[order(observed$cell),,drop=FALSE]
      rownames(observed)<-NULL
      if (!is.null(expected) && !identical(observed,expected)) {good<-FALSE;error<-"complete cell/count parity failed"}
      if (is.null(expected)) expected<-observed
    }
    laps[[i]] <- data.frame(iteration=i,elapsed_s=elapsed,peak_rss_bytes=rss,exit_code=status,
      status=if(good)"PASS"else"FAIL",error)
    write.table(do.call(rbind,laps),file.path(receipts,"iterations.tsv"),sep="\t",row.names=FALSE)
    total <- total+elapsed
    if (!good || total>=5) break
  }
  file.copy(stdout,output,overwrite=FALSE)
  data <- data.frame(engine,operation,cells,threads,replicate,status=if(good)"PASS"else"FAIL",error,
    elapsed_s=total/i,measured_s=total,iterations=i,peak_rss_bytes=max(vapply(laps,function(x)x$peak_rss_bytes,0)),
    exit_code=status,stdout=output,stderr=receipts)
  cat(slug,data$status,sprintf("%.3fms %.1fMiB; %d CLIs / %.3fs",total/i*1000,data$peak_rss_bytes/1024^2,i,total),"\n")
  list(row=data,expected=expected)
}

for (cells in c(1024L,2048L,4096L)) {
  base <- normalizePath(file.path(out,paste0("n",cells)),mustWork=FALSE)
  nrecords <- prepare_input(cells,base)
  for (rep in 1:3) {
    archive <- file.path(base,sprintf("cohort-r%d.aie",rep))
    built <- measure("gravlax","prepare",cells,rep,aie,
      c("ingest-archive",shQuote(file.path(base,"work/sample_a.bam")),"--whitelist",shQuote(file.path(base,"barcodes.txt")),
        "--out",shQuote(archive),"--geometry-fidelity"),base,file.path(base,paste0("prepare-gravlax-r",rep,".out")))
    rows[[length(rows)+1L]]<-transform(built$row,input_records=nrecords,input_bytes=file.info(file.path(base,"work/sample_a.bam"))$size,
      prepared_bytes=if(file.exists(archive))file.info(archive)$size else NA_real_)
    workdir <- file.path(base,paste0("sql-r",rep))
    dir.create(file.path(workdir,"work"),recursive=TRUE,showWarnings=FALSE)
    for (sample in c("a","b")) file.symlink(file.path(base,paste0("work/sample_",sample,".bam")),
      file.path(workdir,paste0("work/sample_",sample,".bam")))
    dir.create(file.path(workdir,"ext"),showWarnings=FALSE)
    file.symlink(normalizePath("ext/duckhts.duckdb_extension"),file.path(workdir,"ext/duckhts.duckdb_extension"))
    settings <- sprintf("SET threads=%d; SET memory_limit='1GiB'; SET max_temp_directory_size='512MiB';\n",threads)
    sql_path <- file.path(workdir,"prepare.sql")
    writeLines(paste0(settings,load_sql),sql_path)
    original <- getwd();setwd(workdir)
    built <- measure("sql","prepare",cells,rep,duckdb,c("-unsigned","-bail","-f",shQuote(sql_path)),base,
      file.path(base,paste0("prepare-sql-r",rep,".out")))
    setwd(original)
    bytes <- sum(file.info(list.files(file.path(workdir,"work"),pattern="\\.parquet$",full.names=TRUE))$size)
    rows[[length(rows)+1L]]<-transform(built$row,input_records=nrecords,input_bytes=file.info(file.path(base,"work/sample_a.bam"))$size,
      prepared_bytes=bytes)
    stopifnot(built$row$status=="PASS", file.exists(archive), bytes<=2*1024^3)
    for (op in names(queries)) {
      target <- if(op=="region")"chr1:1-100"else"chr1:14-24"
      native <- measure("gravlax",op,cells,rep,aie,c("query",shQuote(archive),op,target,"--format","tsv","--top","0"),
        base,file.path(base,sprintf("%s-gravlax-r%d.tsv",op,rep)))
      rows[[length(rows)+1L]]<-transform(native$row,input_records=nrecords,input_bytes=NA_real_,prepared_bytes=NA_real_)
      sql_path <- file.path(workdir,paste0(op,".sql"))
      writeLines(c(settings,queries[[op]]),sql_path)
      setwd(workdir)
      result <- measure("sql",op,cells,rep,duckdb,c("-unsigned","-bail","-csv","-f",shQuote(sql_path)),base,
        file.path(base,sprintf("%s-sql-r%d.csv",op,rep)),native$expected)
      setwd(original)
      rows[[length(rows)+1L]]<-transform(result$row,input_records=nrecords,input_bytes=NA_real_,prepared_bytes=NA_real_)
      write.table(do.call(rbind,rows),file.path(out,"raw.tsv"),sep="\t",row.names=FALSE)
    }
  }
}
raw<-do.call(rbind,rows)
write.table(raw,file.path(out,"raw.tsv"),sep="\t",row.names=FALSE)
writeLines(c(paste("DuckDB:",system2(duckdb,"--version",stdout=TRUE)),
  paste("Gravlax:",system2(aie,"--version",stdout=TRUE)),paste("Machine:",paste(Sys.info(),collapse=" ")),
  paste("Protocol: BENCHMARK_PROTOCOL.md; fresh CLI batches; threads",threads,"; no retry")),file.path(out,"environment.txt"))
if(any(raw$status!="PASS"))stop("Benchmark contains failed cells; retain raw evidence")
