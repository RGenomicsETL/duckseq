#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(LDZipMatrix)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop("Usage: parity_regions.R <region-prefix> <bits>")
prefix <- args[[1L]]
bits <- as.integer(args[[2L]])
scale <- 2^(bits - 1L) - 1
row_group <- as.integer(Sys.getenv("LDZIP_ROW_GROUP", "262144"))
zstd_level <- as.integer(Sys.getenv("LDZIP_ZSTD_LEVEL", "9"))
parquet_dir <- paste0(prefix, "-b", bits, "-parquet-rg", row_group, "-z", zstd_level)
ldzip_prefix <- paste0(prefix, "-b", bits)
ld <- LDZipMatrix(ldzip_prefix)
if (!file.exists(paste0(ldzip_prefix, ".sqlite"))) buildIndex(ld)
variants <- fetchVariants(ld, seq_len(dim(ld)[1L]))
vcor <- read.delim(paste0(prefix, ".vcor"), comment.char = "", check.names = FALSE,
                   stringsAsFactors = FALSE)
names(vcor)[1L] <- sub("^#", "", names(vcor)[1L])
key <- paste(variants$ID, variants$REF, variants$ALT, sep = "\034")
i <- match(paste(vcor$ID_A, vcor$REF_A, vcor$ALT_A, sep = "\034"), key)
j <- match(paste(vcor$ID_B, vcor$REF_B, vcor$ALT_B, sep = "\034"), key)
if (anyNA(i) || anyNA(j)) stop("A PLINK pair failed full ID/allele resolution")

quantize <- function(x) {
  x <- readBin(writeBin(x, raw(), size = 4L), what = numeric(), n = length(x), size = 4L)
  round_q <- sign(x) * floor(abs(x) * scale + 0.5)
  decoded <- round_q / scale
  readBin(writeBin(decoded, raw(), size = 4L), what = numeric(), n = length(decoded), size = 4L)
}
expected <- quantize(vcor$UNPHASED_R)
con <- dbConnect(duckdb(), dbdir = ":memory:")
queries <- data.frame(qid = seq_along(i), i = i, j = j)
dbWriteTable(con, "queries", queries, temporary = TRUE)
ld_path <- normalizePath(file.path(parquet_dir, "ld.parquet"))
actual_sql <- dbGetQuery(con, sprintf(
  "SELECT q.qid, CAST(CAST(l.r_q AS REAL) / %d AS REAL) AS r_q FROM queries q LEFT JOIN read_parquet('%s') l USING (i, j) ORDER BY q.qid",
  scale, ld_path))
if (anyNA(actual_sql$r_q) || !identical(as.numeric(actual_sql$r_q), expected))
  stop("SQL values differ from the quantized PLINK input")

for (start in seq.int(1L, length(i), by = 10000L)) {
  at <- start:min(start + 9999L, length(i))
  got <- fetchLD(ld, i[at], j[at], types = "UNPHASED_R", pairwise = TRUE)$UNPHASED_R
  if (!identical(as.numeric(got), expected[at]))
    stop(sprintf("LDZip decoded values differ from PLINK input at pair %d", at[which(got != expected[at])[1L]]))
}
cat(sprintf("PASS %d-bit exact decoded parity for %d PLINK pairs\n", bits, length(i)))

set.seed(42)
selected <- sample.int(nrow(variants), min(100L, nrow(variants)))
threshold <- sqrt(0.8)
for (idx in selected) {
  pos <- variants$POS[idx]
  sql_neighbors <- dbGetQuery(con, sprintf(
    "SELECT l.j FROM read_parquet('%s') l JOIN read_parquet('%s') v ON v.idx = l.j WHERE l.i = %d AND abs(l.r_q::DOUBLE / %d) >= %.17g AND v.chrom = '20' AND v.pos BETWEEN %d AND %d ORDER BY l.j",
    ld_path, normalizePath(file.path(parquet_dir, "variants.parquet")), idx,
    scale, threshold, pos - 100000L, pos + 100000L))$j
  r_neighbors <- getNeighbors(ld, idx, type = "UNPHASED_R", abs_threshold = threshold,
                              genomic_length = 100000L)
  if (!identical(as.integer(sql_neighbors), as.integer(sort(r_neighbors))))
    stop(sprintf("Tag-neighbor mismatch at variant index %d", idx))
}
cat("PASS getNeighbors parity for 100 variants at r2 >= 0.8\n")

ids <- variants$ID
set.seed(2026)
pair_idx <- matrix(sample.int(nrow(variants), 200L, replace = TRUE), ncol = 2L)
by_id <- vapply(seq_len(nrow(pair_idx)), function(k) {
  fetchLD(ld, ids[pair_idx[k, 1L]], ids[pair_idx[k, 2L]], types = "UNPHASED_R")
}, numeric(1L))
id_query <- data.frame(qid = seq_len(nrow(pair_idx)), id_a = ids[pair_idx[, 1L]],
                       id_b = ids[pair_idx[, 2L]])
dbWriteTable(con, "id_queries", id_query, temporary = TRUE)
variants_path <- normalizePath(file.path(parquet_dir, "variants.parquet"))
id_sql <- dbGetQuery(con, sprintf(
  "SELECT q.qid, CAST(CAST(l.r_q AS REAL) / %d AS REAL) AS r_q FROM id_queries q JOIN read_parquet('%s') a ON a.id=q.id_a JOIN read_parquet('%s') b ON b.id=q.id_b LEFT JOIN read_parquet('%s') l ON l.i=a.idx AND l.j=b.idx ORDER BY q.qid",
  scale, variants_path, variants_path, ld_path))$r_q
id_sql[is.na(id_sql)] <- 0
if (!identical(as.numeric(by_id), id_sql)) stop("SQL-joined ID pair lookups differ")
region <- sprintf("20:%d-%d", min(variants$POS[1:100]), max(variants$POS[1:100]))
region_r <- fetchLD(ld, region, region, types = "UNPHASED_R")
region_sql <- dbGetQuery(con, sprintf(
  "SELECT a.idx, b.idx, coalesce(CAST(l.r_q AS REAL) / %d, 0) AS r_q FROM read_parquet('%s') a CROSS JOIN read_parquet('%s') b LEFT JOIN read_parquet('%s') l ON l.i=a.idx AND l.j=b.idx WHERE a.chrom='20' AND b.chrom='20' AND a.pos BETWEEN %d AND %d AND b.pos BETWEEN %d AND %d ORDER BY a.idx,b.idx",
  scale, normalizePath(file.path(parquet_dir, "variants.parquet")),
  normalizePath(file.path(parquet_dir, "variants.parquet")), ld_path,
  min(variants$POS[1:100]), max(variants$POS[1:100]),
  min(variants$POS[1:100]), max(variants$POS[1:100])))
if (!identical(as.numeric(region_sql$r_q), as.vector(region_r)))
  stop("SQL region extraction differs from LDZip region extraction")
cat("PASS ID and region resolution through the SQL variants table\n")

for (size in unique(pmin(c(1000L, 5000L), nrow(variants)))) {
  idx <- seq_len(size)
  matrix_r <- fetchLD(ld, idx, idx, types = "UNPHASED_R")
  expected_values <- as.vector(t(matrix_r))
  sql <- dbGetQuery(con, sprintf(
    "SELECT i,j,r_q FROM read_parquet('%s') WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d ORDER BY i,j",
    ld_path, size, size))
  matrix_sql <- matrix(0, size, size)
  if (nrow(sql)) matrix_sql[cbind(sql$i, sql$j)] <- readBin(writeBin(as.numeric(sql$r_q) / scale, raw(), size = 4L), what = numeric(), n = nrow(sql), size = 4L)
  diag(matrix_sql) <- 1
  if (!identical(as.numeric(matrix_sql), as.numeric(matrix_r)))
    stop(sprintf("SQL submatrix differs at size %d", size))
  cat(sprintf("PASS exact %d-variant submatrix parity\n", size))
}
dbDisconnect(con, shutdown = TRUE)
