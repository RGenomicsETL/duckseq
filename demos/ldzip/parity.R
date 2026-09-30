#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(LDZipMatrix)
})

root <- normalizePath(".", mustWork = TRUE)
work <- file.path(root, "work", "fixture")
dir.create(work, recursive = TRUE, showWarnings = FALSE)
extdata <- system.file("extdata", package = "LDZipMatrix")
prefix <- file.path(extdata, "g1k.chr22.ldzip")
source <- LDZipMatrix(prefix)
variant_source <- read.delim(paste0(prefix, ".vars.txt"), nrows = 48L,
                             check.names = FALSE, stringsAsFactors = FALSE)
ids <- variant_source$ID
n <- length(ids)
input <- fetchLD(source, seq_len(n), seq_len(n), types = "PHASED_R")
input <- as.matrix(input)
input <- (input + t(input)) / 2
input[is.na(input)] <- 0
stopifnot(length(ids) == n)
input_prefix <- file.path(work, "input")
writeBin(as.numeric(input), paste0(input_prefix, ".bin"), size = 4L)
writeLines(ids, paste0(input_prefix, ".bin.vars"))

quantize <- function(x, bits, min_abs = 1e-4) {
  scale <- 2^(bits - 1) - 1
  x[abs(x) < min_abs] <- 0
  sign(x) * floor(abs(x) * scale + 0.5) / scale
}

for (bits in c(8L, 16L)) {
  out <- file.path(work, paste0("fixture-b", bits))
  system2(file.path(root, ".ldzip/cpp/bin/ldzip"),
          c("compress", "plinkSquare", "--ld_file", paste0(input_prefix, ".bin"),
            "--snp_file", paste0(input_prefix, ".bin.vars"), "--output_prefix", out,
            "--bits", bits, "--min", "0.0001", "--type", "PHASED_R"),
          stdout = TRUE, stderr = TRUE) -> log
  status <- attr(log, "status")
  if (!is.null(status) && status != 0L) stop(paste(log, collapse = "\n"))
  decoded <- LDZipMatrix(out)
  actual_n <- dim(decoded)[1L]
  if (actual_n != n) stop(sprintf("LDZip output has %d rows for %d input variants", actual_n, n))
  observed <- as.matrix(fetchLD(decoded, seq_len(n), seq_len(n), types = "PHASED_R"))
  input_f32 <- matrix(readBin(paste0(input_prefix, ".bin"), what = numeric(), n = n * n,
                              size = 4L), nrow = n, ncol = n)
  expected <- quantize(input_f32, bits)
  expected <- matrix(readBin(writeBin(as.vector(expected), raw(), size = 4L),
                            what = numeric(), n = n * n, size = 4L), nrow = n)
  if (!isTRUE(all.equal(observed, expected, tolerance = 0, check.attributes = FALSE))) {
    delta <- max(abs(observed - expected), na.rm = TRUE)
    stop(sprintf("LDZip quantization differs at %d bits (max |delta|=%g)", bits, delta))
  }

  rows <- expand.grid(i = seq_len(n), j = seq_len(n))
  rows$r_q <- as.vector(observed)
  rows <- rows[rows$r_q != 0, ]
  rows <- rows[order(rows$i, rows$j), ]
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  dbWriteTable(con, "ld", rows, temporary = TRUE)
  parquet <- file.path(work, paste0("fixture-b", bits, ".parquet"))
  dbExecute(con, sprintf(
    "COPY (SELECT i, j, r_q FROM ld ORDER BY i, j) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 122880)",
    normalizePath(parquet, mustWork = FALSE)))
  sql <- dbGetQuery(con, sprintf("SELECT i, j, r_q FROM read_parquet('%s') ORDER BY i, j",
                                normalizePath(parquet)))
  ref <- data.frame(i = rows$i, j = rows$j, r_q = rows$r_q)
  if (!isTRUE(all.equal(sql, ref, tolerance = 0, check.attributes = FALSE)))
    stop(sprintf("Parquet round-trip differs at %d bits", bits))

  # SQL resolution uses the variant table's full ID, including its allele template.
  variants <- data.frame(idx = seq_len(n), chrom = variant_source$`#CHROM`,
                         pos = variant_source$POS, id = ids,
                         ref = variant_source$REF, alt = variant_source$ALT)
  dbWriteTable(con, "variants", variants, temporary = TRUE)
  resolved <- dbGetQuery(con, sprintf(
    "SELECT v.idx, v.id FROM variants v WHERE v.id IN (%s) ORDER BY v.idx",
    paste(dbQuoteString(con, ids[1:8]), collapse = ",")))
  if (!identical(resolved$id, ids[1:8])) stop("SQL variant-ID lookup failed")
  lo <- min(variants$pos[1:8])
  hi <- max(variants$pos[1:8])
  by_region <- dbGetQuery(con, sprintf(
    "SELECT idx FROM variants WHERE chrom = '22' AND pos BETWEEN %d AND %d ORDER BY idx",
    lo, hi))
  expected_region <- variants$idx[variants$pos >= lo & variants$pos <= hi]
  if (!identical(by_region$idx, as.integer(expected_region))) stop("SQL region lookup failed")
  cat(sprintf("PASS %d-bit quantization and sorted Parquet round-trip (%d variants, %d stored cells)\n",
              bits, n, nrow(rows)))
  dbDisconnect(con, shutdown = TRUE)
}
