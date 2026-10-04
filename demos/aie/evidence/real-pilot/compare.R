native_lines <- grep("^cell\t", readLines("gravlax-region.tsv"), value=TRUE)
native <- read.delim(text=paste(native_lines,collapse="\n"),header=FALSE,stringsAsFactors=FALSE)
stopifnot(ncol(native)>=3L)
native <- data.frame(cell=native[[2]],gravlax=as.integer(native[[3]]))
sql <- read.csv("sql-region.csv",colClasses=c("character","character","integer"))
sql <- data.frame(cell=sql[[2]],sql=sql[[3]])
stopifnot(!anyDuplicated(native$cell),!anyDuplicated(sql$cell))
joined <- merge(native,sql,by="cell",all=TRUE)
different <- is.na(joined$gravlax)|is.na(joined$sql)|joined$gravlax!=joined$sql
write.csv(joined,"cell-comparison.csv",row.names=FALSE)
write.csv(joined[different,,drop=FALSE],"cell-disagreements.csv",row.names=FALSE)
summary <- data.frame(status=if(any(different))"PARITY_FAIL"else"PASS",native_cells=nrow(native),sql_cells=nrow(sql),
  different_cells=sum(different),missing_native=sum(is.na(joined$gravlax)),missing_sql=sum(is.na(joined$sql)),
  native_count_sum=sum(native$gravlax),sql_count_sum=sum(sql$sql))
write.csv(summary,"admission.csv",row.names=FALSE)
print(read.csv("tag-summary.csv"),row.names=FALSE)
print(summary,row.names=FALSE)
