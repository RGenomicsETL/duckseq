#!/usr/bin/env Rscript
# Independent pairwise overlap graph and scalar CIGAR cursor oracle.
args <- commandArgs(TRUE)
root <- normalizePath(if(length(args))args[[1L]]else".")
work <- Sys.getenv("AIE_EVIDENCE_TEST_DIR",file.path(root,"work/evidence-check"))
if(dir.exists(work))stop("Use a new work/evidence-check directory")
dir.create(work,recursive=TRUE)
cell <- "AAAAAAAAAAAAAAAA-1"
records <- data.frame(name=paste0("r",1:15),flag=c(rep(0L,7),16L,256L,2048L,4L,0L,0L,0L,0L),
  contig=c(rep("chr1",10),"*","chr1","chr1","chr2","chr1"),
  pos=c(1L,8L,14L,70L,5L,30L,35L,2L,9L,10L,0L,6L,7L,1L,2L),
  cigar=c("10M","8M","8M","10M","5M5N5M10N5M","5M4D5M","10M","10M","10M","10M","*","3M","3M","10M","10M"),
  cell=c(rep(cell,11),NA_character_,cell,cell,"AAAAAAAAAAAAAAAA-2"),
  ur=c(rep("AAAAAAAAAAAA",4),"CACACACACACA","GGGGGGGGGGGG","GGGGGGGGGGGG","AAAAAAAAAAAA",
       "TTTTTTTTTTTT","TTTTTTTTTTTA","AAAAAAAAAAAA","AAAAAAAAAAAA",NA_character_,"AAAAAAAAAAAA","AAAAAAAAAAAA"),
  ub=c(rep("CCCCCCCCCCCC",4),"CACACACACACA","GGGGGGGGGGGG","GGGGGGGGGGGG","CCCCCCCCCCCC",
       "CCCCCCCCCCCC","CCCCCCCCCCCC","CCCCCCCCCCCC","CCCCCCCCCCCC","CCCCCCCCCCCC","CCCCCCCCCCCC","CCCCCCCCCCCC"),
  stringsAsFactors=FALSE)
records <- rbind(records,data.frame(name=c("short-a","long-aa"),flag=0L,contig="chr1",pos=2L,cigar="3M",
  cell=cell,ur=c("A","AA"),ub=c("A","AA"),stringsAsFactors=FALSE))
ops <- lapply(records$cigar,function(c)regmatches(c,gregexpr("[0-9]+[MIDNSHP=X]",c))[[1]])
sam <- vapply(seq_len(nrow(records)),function(i) {
  t <- ops[[i]];letter<-sub("^[0-9]+","",t);len<-as.integer(sub("[A-Z=]$","",t))
  qlen <- sum(len[letter %in% c("M","I","S","=","X")])
  seq <- if(qlen)paste(rep("A",qlen),collapse="")else"*"
  qual <- if(qlen)paste(rep("F",qlen),collapse="")else"*"
  tags <- c("NH:i:1","HI:i:1",if(!is.na(records$cell[i]))paste0("CB:Z:",records$cell[i]),
    if(!is.na(records$ur[i]))paste0("UR:Z:",records$ur[i]),paste0("UB:Z:",records$ub[i]),"CR:Z:AAAAAAAAAAAAAAAA")
  paste(c(records$name[i],records$flag[i],records$contig[i],records$pos[i],60,records$cigar[i],"*",0,0,seq,qual,tags),collapse="\t")
},"")
writeLines(c("@HD\tVN:1.6\tSO:unsorted","@SQ\tSN:chr1\tLN:1000","@SQ\tSN:chr2\tLN:1000",sam),file.path(work,"input.sam"))
stopifnot(system2("samtools",c("view","-bS",shQuote(file.path(work,"input.sam")),"-o",shQuote(file.path(work,"input.bam"))))==0L)
end <- records$pos-1L
junction <- list()
for(i in seq_len(nrow(records))) {
  cursor<-records$pos[i]-1L
  for(t in ops[[i]]) {
    op<-sub("^[0-9]+","",t);len<-as.integer(sub("[A-Z=]$","",t))
    if(op=="N")junction[[length(junction)+1L]]<-data.frame(read=i,donor=cursor,acceptor=cursor+len)
    if(op %in% c("M","D","N","=","X"))cursor<-cursor+len
  }
  end[i]<-cursor
}
junction<-do.call(rbind,junction)
for(tag in c("UR","UB")) {
  cache<-file.path(work,paste0(tag,".duckdb"))
  status<-system2(file.path(root,"prepare_evidence.sh"),shQuote(c(file.path(work,"input.bam"),cache,"test",tag,"1")),
    stdout=file.path(work,paste0(tag,"-prepare.out")),stderr=file.path(work,paste0(tag,"-prepare.log")))
  stopifnot(status==0L)
  con<-DBI::dbConnect(duckdb::duckdb(),dbdir=cache,read_only=TRUE)
  umi<-if(tag=="UR")records$ur else records$ub
  valid<-bitwAnd(records$flag,2308L)==0L & !is.na(records$cell) & !is.na(umi) & end>=records$pos
  inds<-which(valid)
  component<-seq_len(nrow(records))
  for(i in inds)for(j in inds[inds>i]) {
    same<-identical(records$cell[i],records$cell[j]) && identical(umi[i],umi[j]) &&
      identical(records$contig[i],records$contig[j]) && bitwAnd(records$flag[i],16L)==bitwAnd(records$flag[j],16L)
    overlap<-records$pos[i]<=end[j] && records$pos[j]<=end[i]
    if(same && overlap)component[component==component[j]]<-component[i]
  }
  canonical<-function(cell,key) {
    d<-data.frame(cell,key)
    d<-unique(d)
    if(!nrow(d))return(data.frame(cell=character(),count=integer()))
    z<-aggregate(list(count=d$key),list(cell=d$cell),length)
    z[order(z$cell),,drop=FALSE]
  }
  for(kind in c("labels","families"))for(chr in c("chr1","chr2"))for(range in list(c(1,100),c(14,19),c(70,79))) {
    hit<-inds[records$contig[inds]==chr & records$pos[inds]<=range[2] & end[inds]>=range[1]]
    keys<-if(kind=="labels")umi else component
    expected<-canonical(records$cell[hit],keys[hit]);rownames(expected)<-NULL
    actual<-DBI::dbGetQuery(con,sprintf("SELECT * FROM aie_region_%s('%s',%d,%d)",kind,chr,range[1],range[2]))
    actual<-data.frame(cell=actual[[2]],count=as.integer(actual[[3]]));rownames(actual)<-NULL
    stopifnot(identical(expected,actual))
  }
  for(kind in c("labels","families"))for(d in c(9L,14L,19L)) {
    hit<-unique(junction$read[junction$donor==d & junction$acceptor==d+if(d==9L)5L else 10L])
    hit<-intersect(hit,inds)
    keys<-if(kind=="labels")umi else component
    expected<-canonical(records$cell[hit],keys[hit]);rownames(expected)<-NULL
    actual<-DBI::dbGetQuery(con,sprintf("SELECT * FROM aie_junction_%s('chr1',%d,%d)",kind,d,d+if(d==9L)5L else 10L))
    actual<-data.frame(cell=actual[[2]],count=as.integer(actual[[3]]));rownames(actual)<-NULL
    stopifnot(identical(expected,actual))
  }
  audit<-DBI::dbGetQuery(con,"SELECT * FROM evidence_audit")
  stopifnot(audit$source_records==nrow(records),audit$nonprimary_or_unmapped==3,audit$missing_cell==1,
    audit$missing_selected_umi==if(tag=="UR")1 else 0)
  DBI::dbDisconnect(con,shutdown=TRUE)
}
cat("PASS: independent CIGAR cursor, pairwise overlap families, both tag policies, variable UMI lengths, GEM groups, missing tags and primary filtering\n")
