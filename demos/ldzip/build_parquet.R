#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) stop("Usage: build_parquet.R <region-prefix> [row-group-size] [zstd-level] [bits]")
prefix <- file.path(normalizePath(dirname(args[[1L]]), mustWork = TRUE), basename(args[[1L]]))
row_group <- if (length(args) >= 2L) as.integer(args[[2L]]) else 122880L
zstd_level <- if (length(args) >= 3L) as.integer(args[[3L]]) else 3L
bits <- if (length(args) >= 4L) as.integer(args[[4L]]) else 8L
if (row_group < 1L || !zstd_level %in% 1:22 || !bits %in% c(8L, 16L)) stop("Invalid Parquet options")

pvar_path <- paste0(prefix, "-vars.pvar")
pvar_header <- grep("^#CHROM\\t", readLines(pvar_path, n = 200L))[1L]
if (is.na(pvar_header)) stop("PLINK variant file has no #CHROM header")
pvar <- read.delim(pvar_path, skip = pvar_header - 1L, comment.char = "",
                   check.names = FALSE, stringsAsFactors = FALSE)
names(pvar)[1L] <- "CHROM"
vcor <- read.delim(paste0(prefix, ".vcor"), comment.char = "", check.names = FALSE,
                   stringsAsFactors = FALSE)
names(vcor)[1L] <- sub("^#", "", names(vcor)[1L])
required <- c("ID_A", "REF_A", "ALT_A", "ID_B", "REF_B", "ALT_B", "UNPHASED_R")
if (!all(required %in% names(vcor))) stop("PLINK output does not match the pinned tutorial columns")
variant_key <- paste(pvar$ID, pvar$REF, pvar$ALT, sep = "\034")
key_a <- paste(vcor$ID_A, vcor$REF_A, vcor$ALT_A, sep = "\034")
key_b <- paste(vcor$ID_B, vcor$REF_B, vcor$ALT_B, sep = "\034")
i <- match(key_a, variant_key)
j <- match(key_b, variant_key)
if (anyNA(i) || anyNA(j)) stop("PLINK LD rows do not resolve to the full allele-template variant key")
r <- readBin(writeBin(vcor$UNPHASED_R, raw(), size = 4L), what = numeric(),
             n = nrow(vcor), size = 4L)
scale <- 2^(bits - 1L) - 1
r_q <- sign(r) * floor(abs(r) * scale + 0.5) / scale
r_q <- readBin(writeBin(r_q, raw(), size = 4L), what = numeric(), n = length(r_q), size = 4L)
r_q[abs(r) < 1e-4] <- 0
keep <- r_q != 0
pairs <- data.frame(i = i[keep], j = j[keep], r_q = r_q[keep])
reverse <- data.frame(i = pairs$j, j = pairs$i, r_q = pairs$r_q)
diagonal <- data.frame(i = seq_len(nrow(pvar)), j = seq_len(nrow(pvar)), r_q = 1)
ld <- rbind(pairs, reverse, diagonal)
ld <- ld[!duplicated(paste(ld$i, ld$j, sep = ":")), ]
variants <- data.frame(idx = seq_len(nrow(pvar)), chrom = as.character(pvar$CHROM),
                       pos = pvar$POS, id = pvar$ID, ref = pvar$REF, alt = pvar$ALT)

outdir <- paste0(prefix, "-b", bits, "-parquet-rg", row_group, "-z", zstd_level)
if (dir.exists(outdir)) unlink(outdir, recursive = TRUE)
dir.create(outdir, recursive = TRUE)
con <- dbConnect(duckdb(), dbdir = ":memory:")
dbWriteTable(con, "variants", variants, temporary = TRUE)
dbWriteTable(con, "ld", ld, temporary = TRUE)
quote_path <- function(path) as.character(dbQuoteString(con, normalizePath(path, mustWork = FALSE)))
dbExecute(con, sprintf(
  "COPY (SELECT idx, chrom, pos, id, ref, alt FROM variants ORDER BY idx) TO %s (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL %d, ROW_GROUP_SIZE %d)",
  quote_path(file.path(outdir, "variants.parquet")), zstd_level, row_group))
dbExecute(con, sprintf(
  "COPY (SELECT i, j, r_q FROM ld ORDER BY i, j) TO %s (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL %d, ROW_GROUP_SIZE %d)",
  quote_path(file.path(outdir, "ld.parquet")), zstd_level, row_group))
cat(sprintf("PARQUET_DIR=%s\nvariants=%d\ninput_pairs=%d\nstored_rows=%d\nrow_group_size=%d\nzstd_level=%d\n",
            normalizePath(outdir), nrow(variants), nrow(vcor), nrow(ld), row_group, zstd_level))
dbDisconnect(con, shutdown = TRUE)
