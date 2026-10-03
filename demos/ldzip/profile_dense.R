#!/usr/bin/env Rscript
# Allocation and query-plan diagnostic; not a repeated performance benchmark.
# Usage: Rscript profile_dense.R [prefix] [bits] [size] [original|unordered|linear]
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(LDZipMatrix)
})

profile_dense <- function(prefix, bits, size, mode) {
  mode <- match.arg(mode, c("original", "unordered", "linear"))
  stopifnot(bits %in% c(8L, 16L), size > 0L)
  scale <- 2^(bits - 1L) - 1L
  parquet <- sprintf("%s-b%d-parquet-rg262144-z9/ld.parquet", prefix, bits)
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  profile <- tempfile("dense-allocations-", fileext = ".txt")
  on.exit({
    Rprofmem(NULL)
    unlink(profile)
    dbDisconnect(con, shutdown = TRUE)
  })
  sql <- sprintf(paste0("SELECT i,j,CAST(CAST(r_q AS REAL) / %d AS REAL) AS r ",
    "FROM read_parquet(%s) WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d%s"),
    scale, dbQuoteString(con, parquet), size, size,
    if (mode == "original") " ORDER BY i,j" else "")
  cat("R:", as.character(getRversion()), "DuckDB:", as.character(packageVersion("duckdb")),
      "threads:", dbGetQuery(con, "SELECT current_setting('threads') AS n")$n,
      "mode:", mode, "\n")
  cat(dbGetQuery(con, paste("EXPLAIN ANALYZE", sql))$explain_value, "\n")

  Rprofmem(profile, threshold = 64 * 1024^2)
  result <- dbGetQuery(con, sql)
  m <- matrix(0, size, size)
  tracemem(m)
  if (nrow(result)) {
    if (mode == "linear") {
      m[result$i + (result$j - 1L) * size] <- result$r
    } else {
      m[cbind(result$i, result$j)] <- as.numeric(result$r)
    }
  }
  if (mode == "linear") {
    m[seq.int(1L, size * size, by = size + 1L)] <- 1
  } else {
    diag(m) <- 1
  }
  untracemem(m)
  Rprofmem(NULL)
  allocations <- readLines(profile)
  cat("Stored rows:", nrow(result), "sparse R bytes:", as.numeric(object.size(result)),
      "dense R bytes:", as.numeric(object.size(m)), "\n")
  cat("Allocations at least 64 MiB:\n", paste(allocations[grepl("^[0-9]", allocations)], collapse = "\n"), "\n")

  ld <- LDZipMatrix(sprintf("%s-b%d", prefix, bits))
  expected <- fetchLD(ld, seq_len(size), seq_len(size), types = "UNPHASED_R")
  stopifnot(identical(unname(m), unname(expected)))
  cat("PASS exact dense matrix values against LDZip\n")
}

args <- commandArgs(trailingOnly = TRUE)
profile_dense(
  if (length(args) >= 1L) args[[1L]] else "work/derived/region-4x",
  if (length(args) >= 2L) as.integer(args[[2L]]) else 16L,
  if (length(args) >= 3L) as.integer(args[[3L]]) else 5000L,
  if (length(args) >= 4L) args[[4L]] else "original"
)
