#!/usr/bin/env Rscript
# Three fresh CLI processes per cell; no padding loops or discarded failures.
args<-commandArgs(TRUE)
if(length(args)!=2L)stop("usage: measure_real.R DERIVED_BAM_DIR NEW_OUTPUT_DIR (from demos/aie)")
inputs<-normalizePath(args[[1]],mustWork=TRUE)
out<-normalizePath(args[[2]],mustWork=FALSE)
if(dir.exists(out))stop("Output directory must be new")
dir.create(out,recursive=TRUE)
out<-normalizePath(out)
threads_set<-c(1L,4L)
Sys.setenv(OMP_NUM_THREADS="1",OPENBLAS_NUM_THREADS="1",MKL_NUM_THREADS="1")
duckdb<-Sys.getenv("DUCKDB",Sys.which("duckdb"))
aie<-normalizePath(".gravlax/target/release/aie")
ext<-normalizePath("ext/duckhts.duckdb_extension")
prepare<-normalizePath("prepare_evidence.sh")
rows<-list()
measure<-function(engine,op,n,threads,rep,command,args) {
  stem<-file.path(out,sprintf("%s-%s-n%d-t%d-r%d",engine,op,n,threads,rep))
  start<-proc.time()[["elapsed"]]
  status<-system2("/usr/bin/timeout",c("180s","/usr/bin/time","-f",shQuote("%M"),"-o",shQuote(paste0(stem,".time")),
    shQuote(command),args),stdout=paste0(stem,".out"),stderr=paste0(stem,".log"))
  elapsed<-proc.time()[["elapsed"]]-start
  rss<-suppressWarnings(as.numeric(tail(readLines(paste0(stem,".time"),warn=FALSE),1)))*1024
  pass<-status==0L && elapsed<=180 && is.finite(rss) && rss<=4*1024^3
  row<-data.frame(engine,operation=op,records=n,threads,replicate=rep,status=if(pass)"PASS"else"RESOURCE_OR_RUNTIME_FAIL",
    elapsed_s=elapsed,peak_rss_bytes=rss,exit_code=status,prepared_bytes=NA_real_,output_rows=NA_integer_,count_sum=NA_real_,stem)
  rows[[length(rows)+1L]]<<-row
  write.table(do.call(rbind,rows),file.path(out,"raw.tsv"),sep="\t",row.names=FALSE)
  cat(basename(stem),row$status,sprintf("%.3fs %.1fMiB",elapsed,rss/1024^2),"\n")
  list(pass=pass,stdout=paste0(stem,".out"),index=length(rows))
}
for(n in c(1000000L,2000000L,4000000L)) {
  bam<-file.path(inputs,paste0("n",n,".bam"))
  stopifnot(file.exists(bam))
  wl<-file.path(out,paste0("n",n,"-whitelist.txt"))
  metadata<-file.path(out,paste0("n",n,"-input.csv"))
  q<-sprintf("LOAD '%s'; SET threads=1; CREATE TEMP TABLE tags AS SELECT CB FROM read_bam('%s',standard_tags:=TRUE); COPY (SELECT count(*) AS records,count(DISTINCT CB) AS cells,count(*) FILTER(WHERE CB !~ '^[ACGT]{16}-1$') AS unsupported_gem FROM tags) TO '%s' (HEADER,DELIMITER ','); COPY(SELECT DISTINCT substr(CB,1,16) FROM tags ORDER BY 1)TO '%s'(HEADER FALSE);",ext,bam,metadata,wl)
  stopifnot(system2(duckdb,c("-unsigned","-bail","-c",shQuote(q)),stdout=file.path(out,paste0("n",n,"-metadata.out")),stderr=file.path(out,paste0("n",n,"-metadata.log")))==0L)
  m<-read.csv(metadata);stopifnot(m$records==n,m$unsupported_gem==0L)
  for(threads in threads_set)for(rep in 1:3) {
    Sys.setenv(RAYON_NUM_THREADS=as.character(threads),DUCKDB=duckdb,DUCKHTS_EXTENSION=ext,
      AIE_MEMORY_LIMIT="2GiB",AIE_SPILL_LIMIT="2GiB")
    cache<-file.path(out,sprintf("cache-n%d-t%d-r%d.duckdb",n,threads,rep))
    archive<-file.path(out,sprintf("archive-n%d-t%d-r%d.aie",n,threads,rep))
    native<-measure("gravlax","prepare",n,threads,rep,aie,c("ingest-archive",shQuote(bam),"--whitelist",shQuote(wl),"--out",shQuote(archive),"--geometry-fidelity"))
    product<-measure("sql","prepare",n,threads,rep,prepare,shQuote(c(bam,cache,"pbmc","UR",as.character(threads))))
    for(engine in c("gravlax","sql")) {
      result<-if(engine=="gravlax")native else product
      state<-if(engine=="gravlax")archive else cache
      if(file.exists(state)) {
        bytes<-file.info(state)$size
        rows[[result$index]]$prepared_bytes<-bytes
        if(bytes>4*1024^3){rows[[result$index]]$status<-"PREPARED_SIZE_FAIL";result$pass<-FALSE}
      }
      if(!result$pass)next
      for(op in c("region-full","region-window")) {
        hi<-if(op=="region-full")248956422L else 3000000L
        if(engine=="gravlax") {
          queried<-measure(engine,op,n,threads,rep,aie,c("query",shQuote(state),"region",paste0("1:1-",hi),"--format","tsv","--top","0"))
          if(queried$pass) {
            lines<-grep("^cell\t",readLines(queried$stdout),value=TRUE)
            fields<-strsplit(lines,"\t",fixed=TRUE)
            counts<-as.numeric(vapply(fields,`[[`,"",3L))
            rows[[queried$index]]$output_rows<-length(counts)
            rows[[queried$index]]$count_sum<-sum(counts)
          }
        } else for(kind in c("labels","families")) {
          sql<-sprintf("SET threads=%d; SET memory_limit='2GiB'; SET max_temp_directory_size='2GiB'; SELECT * FROM aie_region_%s('1',1,%d);",threads,kind,hi)
          queried<-measure(engine,paste(op,kind,sep="-"),n,threads,rep,duckdb,c("-bail","-csv",shQuote(state),"-c",shQuote(sql)))
          if(queried$pass) {
            data<-read.csv(queried$stdout,colClasses=c("character","character","numeric"))
            rows[[queried$index]]$output_rows<-nrow(data)
            rows[[queried$index]]$count_sum<-sum(data[[3]])
          }
        }
      }
    }
    write.table(do.call(rbind,rows),file.path(out,"raw.tsv"),sep="\t",row.names=FALSE)
    # Passed states are rebuilt; failed partial states and all receipts remain available.
    if(rows[[native$index]]$status=="PASS" && rows[[product$index]]$status=="PASS")
      unlink(c(cache,paste0(cache,".wal"),archive),recursive=FALSE)
  }
}
writeLines(c(paste("DuckDB:",system2(duckdb,"--version",stdout=TRUE)),paste("Gravlax:",system2(aie,"--version",stdout=TRUE)),
  paste("R:",R.version.string),paste("Host:",paste(Sys.info(),collapse=" ")),
  "Source/derived BAMs: tmpfs; counting contract: CB+UR labels/families, not Gravlax UMI classes; no equal-output speedup claim"),file.path(out,"environment.txt"))
write.table(do.call(rbind,rows),file.path(out,"raw.tsv"),sep="\t",row.names=FALSE)
if(any(vapply(rows,function(r)r$status!="PASS",TRUE)))stop("Retained failed cells; see raw.tsv")
