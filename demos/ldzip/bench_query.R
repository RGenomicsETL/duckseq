#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 5L) stop("Usage: bench_query.R <region-prefix> <bits> <engine> <operation> <replicate>")
prefix <- args[[1L]]
bits <- as.integer(args[[2L]])
engine <- args[[3L]]
operation <- args[[4L]]
replicate <- as.integer(args[[5L]])
stopifnot(engine %in% c("ldzip", "dbi", "cli"))
if (engine == "ldzip") {
  suppressPackageStartupMessages(library(LDZipMatrix))
} else {
  suppressPackageStartupMessages({
    library(DBI)
    library(duckdb)
  })
}
parquet_dir <- paste0(prefix, "-b", bits, "-parquet-rg122880-z3")
ld_path <- normalizePath(file.path(parquet_dir, "ld.parquet"))
variants_path <- normalizePath(file.path(parquet_dir, "variants.parquet"))
if (engine == "ldzip") {
  ld <- LDZipMatrix(paste0(prefix, "-b", bits))
  variants <- fetchVariants(ld, seq_len(dim(ld)[1L]))
  names(variants)[names(variants) == "CHROM"] <- "chrom"
} else {
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  variants <- dbGetQuery(con, sprintf("SELECT idx, chrom, pos, id FROM read_parquet('%s') ORDER BY idx", variants_path))
}
region_number <- as.integer(sub(".*region-(1|2|4)x$", "\\1", prefix))
size <- c(pair_1000 = 1000L, pair_10000 = 10000L, tags_100 = 100L,
          submatrix_1000 = 1000L, submatrix_5000 = 5000L)[[operation]]
if (is.null(size)) stop("Unknown benchmark operation")
seed <- 74000L + region_number * 100L + bits + size
set.seed(seed)
query_file <- tempfile(pattern = "ldzip-query-", tmpdir = "work/perf/queries", fileext = ".csv")
dir.create(dirname(query_file), recursive = TRUE, showWarnings = FALSE)

if (operation %in% c("pair_1000", "pair_10000")) {
  query <- data.frame(qid = seq_len(size), i = sample.int(nrow(variants), size, replace = TRUE),
                      j = sample.int(nrow(variants), size, replace = TRUE))
  type <- "pairs"
} else if (operation == "tags_100") {
  query <- data.frame(qid = seq_len(size), i = sample.int(nrow(variants), size))
  type <- "tags"
} else {
  if (size > nrow(variants)) stop("Submatrix exceeds variant count")
  query <- data.frame(i = seq_len(size), j = seq_len(size))
  type <- "submatrix"
}
write.csv(query, query_file, row.names = FALSE, quote = FALSE)

sql_pairs <- sprintf(
  "SELECT q.qid, l.r_q FROM read_csv_auto('%s') q LEFT JOIN read_parquet('%s') l USING (i,j) ORDER BY q.qid",
  query_file, ld_path)
sql_tags <- sprintf(
  "SELECT t.qid, l.j FROM read_csv_auto('%s') t JOIN read_parquet('%s') qv ON qv.idx=t.i JOIN read_parquet('%s') l ON l.i=t.i JOIN read_parquet('%s') nv ON nv.idx=l.j WHERE abs(l.r_q)>=%.17g AND nv.chrom=qv.chrom AND nv.pos BETWEEN qv.pos-100000 AND qv.pos+100000 ORDER BY t.qid,l.j",
  query_file, variants_path, ld_path, variants_path, sqrt(0.8))
sql_sub <- sprintf(
  "SELECT coalesce(l.r_q,0) AS r_q FROM range(1,%d) a(i) CROSS JOIN range(1,%d) b(j) LEFT JOIN read_parquet('%s') l ON l.i=a.i AND l.j=b.j ORDER BY a.i,b.j",
  size + 1L, size + 1L, ld_path)
query_sql <- switch(type, pairs = sql_pairs, tags = sql_tags, submatrix = sql_sub)
elapsed <- system.time({
  if (engine == "ldzip") {
    if (type == "pairs") {
      ord <- order(query$i)
      fetchLD(ld, query$i[ord], query$j[ord], types = "UNPHASED_R", pairwise = TRUE)
    } else if (type == "tags") {
      lapply(query$i, function(i) getNeighbors(ld, i, type = "UNPHASED_R",
                                               abs_threshold = sqrt(0.8), genomic_length = 100000L))
    } else {
      fetchLD(ld, seq_len(size), seq_len(size), types = "UNPHASED_R")
    }
  } else if (engine == "dbi") {
    result <- dbGetQuery(con, query_sql)
    if (type == "submatrix") matrix(result$r_q, nrow = size, byrow = TRUE) else nrow(result)
  } else {
    cli <- normalizePath(".cache/duckdb", mustWork = TRUE)
    cli_sql <- if (type == "submatrix") sprintf("COPY (%s) TO '/dev/null' (FORMAT CSV, HEADER false);", query_sql) else query_sql
    timing <- tempfile()
    status <- system2("/usr/bin/time", c("-f", shQuote("%e %M"), cli, "-c", shQuote(cli_sql)),
                      stdout = "/dev/null", stderr = timing)
    if (status != 0L) stop("DuckDB CLI query failed")
    values <- readLines(timing, warn = FALSE)
    metric <- tail(values[grepl("^[0-9.]+ [0-9]+$", values)], 1L)
    if (length(metric) == 0L) stop("DuckDB CLI timing was not captured")
    pieces <- strsplit(metric, " ", fixed = TRUE)[[1L]]
    cat(sprintf("%s\t%s\tCLI-child-RSS-kB=%s\n", operation,
                as.numeric(pieces[1L]) * 1000, pieces[2L]))
    unlink(timing)
    dbDisconnect(con, shutdown = TRUE)
    unlink(query_file)
    quit(save = "no", status = 0L)
  }
})
cat(sprintf("%s\t%.3f\tNA\n", operation, elapsed[["elapsed"]] * 1000))
if (engine != "ldzip") dbDisconnect(con, shutdown = TRUE)
unlink(query_file)
