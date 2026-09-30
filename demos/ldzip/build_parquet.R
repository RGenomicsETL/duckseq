#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) stop("Usage: build_parquet.R <region-prefix> [row-group-size] [zstd-level] [bits]")
prefix <- file.path(normalizePath(dirname(args[[1L]]), mustWork = TRUE), basename(args[[1L]]))
row_group <- if (length(args) >= 2L) as.integer(args[[2L]]) else 262144L
zstd_level <- if (length(args) >= 3L) as.integer(args[[3L]]) else 9L
bits <- if (length(args) >= 4L) as.integer(args[[4L]]) else 8L
if (row_group < 1L || !zstd_level %in% 1:22 || !bits %in% c(8L, 16L)) stop("Invalid Parquet options")
pvar_path <- normalizePath(paste0(prefix, "-vars.pvar"))
vcor_path <- normalizePath(paste0(prefix, ".vcor"))
pvar_lines <- readLines(pvar_path, n = 200L, warn = FALSE)
pvar_header <- which(startsWith(pvar_lines, "#CHROM\t"))[1L]
if (is.na(pvar_header)) stop("PLINK variant file has no #CHROM header")
outdir <- paste0(prefix, "-b", bits, "-parquet-rg", row_group, "-z", zstd_level)
if (dir.exists(outdir)) unlink(outdir, recursive = TRUE)
dir.create(outdir, recursive = TRUE)
con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
quote_path <- function(path) as.character(dbQuoteString(con, path))
scale <- 2^(bits - 1L) - 1L
storage_type <- if (bits == 8L) "TINYINT" else "SMALLINT"
mutant <- Sys.getenv("LDZIP_MUTANT", "")
rounding <- if (mutant == "wrong-rounding") "floor(CAST(CAST(v.UNPHASED_R AS REAL) AS DOUBLE) * %d)" else "round(CAST(CAST(v.UNPHASED_R AS REAL) AS DOUBLE) * %d)"
quantize <- "CAST(CASE WHEN abs(CAST(v.UNPHASED_R AS REAL)) < 0.0001 THEN 0 ELSE "
quantize <- paste0(quantize, sprintf(rounding, scale), sprintf(" END AS %s)", storage_type))
if (mutant == "wrong-threshold") threshold <- 0.2 else threshold <- 0.0001
if (mutant == "shifted-index") index_a <- "a.idx + 1" else index_a <- "a.idx"
if (mutant == "ignore-allele-template") allele_join <- "a.id=v.ID_A AND a.ref=v.REF_A AND a.alt IS NULL" else allele_join <- "a.id=v.ID_A AND a.ref=v.REF_A AND a.alt=v.ALT_A"
if (mutant == "upper-triangle") direction_sql <- "directions AS (SELECT i,j,r_q FROM pairs)" else direction_sql <- "directions AS (SELECT i,j,r_q FROM pairs UNION ALL SELECT j,i,r_q FROM pairs)"
pvar_sql <- sprintf("read_csv(%s, delim='\\t', header=true, skip=%d, columns={'#CHROM':'VARCHAR','POS':'BIGINT','ID':'VARCHAR','REF':'VARCHAR','ALT':'VARCHAR','FILTER':'VARCHAR','INFO':'VARCHAR'})", quote_path(pvar_path), pvar_header - 1L)
vcor_sql <- sprintf("read_csv(%s, delim='\\t', header=true, columns={'ID_A':'VARCHAR','REF_A':'VARCHAR','ALT_A':'VARCHAR','ID_B':'VARCHAR','REF_B':'VARCHAR','ALT_B':'VARCHAR','UNPHASED_R':'FLOAT'})", quote_path(vcor_path))
variants_cte <- sprintf("variants AS (SELECT row_number() OVER ()::INTEGER AS idx, \"#CHROM\" AS chrom, POS::BIGINT AS pos, ID AS id, REF AS ref, ALT AS alt, FILTER AS filter, INFO AS info FROM %s)", pvar_sql)
pairs_cte <- sprintf("pairs AS (SELECT %s AS i, b.idx AS j, %s AS r_q FROM %s v JOIN variants a ON %s JOIN variants b ON b.id=v.ID_B AND b.ref=v.REF_B AND b.alt=v.ALT_B WHERE abs(CAST(v.UNPHASED_R AS REAL)) >= %g)", index_a, quantize, vcor_sql, allele_join, threshold)
all_ctes <- sprintf("WITH %s, %s, %s, ld AS (SELECT i,j,r_q FROM directions UNION ALL SELECT idx,idx,%d::%s FROM variants WHERE NOT EXISTS (SELECT 1 FROM directions WHERE directions.i=idx AND directions.j=idx))", variants_cte, pairs_cte, direction_sql, scale, storage_type)
missing <- dbGetQuery(con, sprintf("%s SELECT count(*) AS n FROM %s v LEFT JOIN variants a ON a.id=v.ID_A AND a.ref=v.REF_A AND a.alt=v.ALT_A LEFT JOIN variants b ON b.id=v.ID_B AND b.ref=v.REF_B AND b.alt=v.ALT_B WHERE a.idx IS NULL OR b.idx IS NULL", sprintf("WITH %s", variants_cte), vcor_sql))$n
if (missing != 0) stop("PLINK LD rows do not resolve to the full allele-template variant key")
options_sql <- sprintf("FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL %d, ROW_GROUP_SIZE %d, PARQUET_VERSION V2", zstd_level, row_group)
invisible(dbExecute(con, sprintf("COPY (WITH %s SELECT idx,chrom,pos,id,ref,alt,filter,info FROM variants ORDER BY idx) TO %s (%s)", variants_cte, quote_path(file.path(outdir, "variants.parquet")), options_sql)))
invisible(dbExecute(con, sprintf("COPY (%s SELECT i,j,r_q FROM ld ORDER BY i,j) TO %s (%s)", all_ctes, quote_path(file.path(outdir, "ld.parquet")), options_sql)))
cat(sprintf("PARQUET_DIR=%s\nrow_group_size=%d\nzstd_level=%d\n", normalizePath(outdir), row_group, zstd_level))
