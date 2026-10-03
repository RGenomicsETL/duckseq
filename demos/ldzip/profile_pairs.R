#!/usr/bin/env Rscript
# Pair grouping diagnostic; timings do not replace the budgeted benchmark.
# Usage: Rscript profile_pairs.R [prefix] [bits] [rep] [original|column_grouped]
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(LDZipMatrix)
})

profile_pairs <- function(prefix, bits, rep, mode) {
  mode <- match.arg(mode, c("original", "column_grouped"))
  stopifnot(bits %in% c(8L, 16L), rep > 0L)
  scale <- 2^(bits - 1L) - 1L
  parquet <- sprintf("%s-b%d-parquet-rg262144-z9", prefix, bits)
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  on.exit(dbDisconnect(con, shutdown = TRUE))
  vars <- dbGetQuery(con, sprintf("SELECT idx FROM read_parquet(%s)",
    dbQuoteString(con, file.path(parquet, "variants.parquet"))))
  set.seed(9000L + rep)
  query <- data.frame(qid = seq_len(10000L),
    i = sample(vars$idx, 10000L, replace = TRUE),
    j = sample(vars$idx, 10000L, replace = TRUE))
  ld <- LDZipMatrix(sprintf("%s-b%d", prefix, bits))
  timing <- system.time({
    o <- if (mode == "original") order(query$i) else order(query$j, query$i)
    result <- fetchLD(ld, query$i[o], query$j[o], types = "UNPHASED_R", pairwise = TRUE)
    decoded <- result[[1L]][order(o)]
  })
  dbWriteTable(con, "query_input", query)
  sql <- sprintf(paste0("SELECT q.qid, CAST(CAST(coalesce(l.r_q,0) AS REAL)/%d AS REAL) AS r ",
    "FROM query_input q LEFT JOIN read_parquet(%s) l ON l.i=q.i AND l.j=q.j ORDER BY q.qid"),
    scale, dbQuoteString(con, file.path(parquet, "ld.parquet")))
  expected <- dbGetQuery(con, sql)
  stopifnot(identical(decoded, expected$r))
  cat("Diagnostic only; peak RSS is not measured.\n")
  cat(mode, "rep", rep, "elapsed_s", timing[["elapsed"]], "checksum", sum(decoded),
      "PASS decoded SQL parity\n")
}

args <- commandArgs(trailingOnly = TRUE)
profile_pairs(
  if (length(args) >= 1L) args[[1L]] else "work/derived/region-4x",
  if (length(args) >= 2L) as.integer(args[[2L]]) else 16L,
  if (length(args) >= 3L) as.integer(args[[3L]]) else 1L,
  if (length(args) >= 4L) args[[4L]] else "original"
)
