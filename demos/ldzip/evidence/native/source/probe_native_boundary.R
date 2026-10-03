#!/usr/bin/env Rscript
# The complete C column is constructed/consumed, but no matrix is retained in SQL.
source("measure_native.R")
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L)
threads <- as.integer(args[[1L]])
profile_path <- normalizePath(args[[2L]], mustWork = FALSE)
stopifnot(threads %in% c(1L, 4L))
n <- 5000L
scale <- 32767L
path <- normalizePath(sprintf("%s-b16-parquet-rg262144-z9/ld.parquet", prefix))
code <- paste(readLines(native_file), collapse = "\n")
parts <- strsplit(code, "int ld_dense_column_final(", fixed = TRUE)[[1L]]
stopifnot(length(parts) == 2L)
final_parts <- strsplit(parts[[2L]], "void ld_dense_column_destroy(", fixed = TRUE)[[1L]]
stopifnot(length(final_parts) == 2L)
builder <- paste0("int ld_dense_column_build(", final_parts[[1L]])
builder <- sub("ducktinycc_result_alloc(bytes)", "ducktinycc_malloc(bytes)", builder, fixed = TRUE)
builder <- sub("/* DuckDB copies this chunk-owned result after final; the aggregate must not free it. */",
               "/* The native consumer releases this owned buffer after consumption. */", builder, fixed = TRUE)
code <- paste0(parts[[1L]], builder,
  "int ld_dense_column_final(ld_dense_column_state *st, double *out) {\n",
  "  ducktinycc_list_t values = {0};\n",
  "  uint64_t k; double total = 0;\n",
  "  if (!ld_dense_column_build(st, &values)) return 0;\n",
  "  for (k = 0; k < values.len; k++) total += ((const double *)values.ptr)[k];\n",
  "  ducktinycc_free((void *)values.ptr);\n",
  "  *out = total; return 1;\n}\n",
  "void ld_dense_column_destroy(", final_parts[[2L]])
writeLines(code, paste0(profile_path, ".c"))
con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
setup_start <- proc.time()[["elapsed"]]
settings(con, threads, paste0(profile_path, ".spill"))
dbExecute(con, paste("LOAD", dbQuoteString(con, normalizePath(extension_file))))
registered <- dbGetQuery(con, paste0(
  "SELECT * FROM tcc_module(mode:='quick_compile',kind:='aggregate',",
  "symbol:='ld_dense_column',sql_name:='ld_column_checksum',return_type:='f64',",
  "arg_types:=['i64','i64','i64','i64','i64'],source:=", dbQuoteString(con, code), ")"))
if (!isTRUE(registered$ok)) stop(paste(unlist(registered), collapse = " | "))
dbExecute(con, paste("SET VARIABLE ld_path =", dbQuoteString(con, path)))
dbExecute(con, sprintf("SET VARIABLE matrix_n = %d", n))
dbExecute(con, sprintf("SET VARIABLE quant_scale = %d", scale))
selected <- read_templates(template_file)[[2L]]
selected <- sub("ld_dense_column(i, j, q, n, scale)",
                "ld_column_checksum(i, j, q, n, scale)", selected, fixed = TRUE)
expected <- dbGetQuery(con, sprintf(paste0(
  "SELECT %d + coalesce(sum(CAST(CAST(r_q AS REAL)/%d AS REAL)::DOUBLE),0) AS total ",
  "FROM read_parquet(%s) WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d AND i<>j"),
  n, scale, dbQuoteString(con, path), n, n))$total
setup_s <- proc.time()[["elapsed"]] - setup_start
run_once <- function() {
  dbExecute(con, paste("CREATE TEMP TABLE native_consumed AS", selected))
  got <- dbGetQuery(con, "SELECT count(*) AS n, count(*) FILTER (WHERE vals IS NULL) AS bad, sum(vals) AS total FROM native_consumed")
  stopifnot(got$n == n, got$bad == 0, is.finite(got$total),
            abs(got$total - expected) <= 1e-12 * max(1, abs(expected)))
  dbExecute(con, "DROP TABLE native_consumed")
}
durations <- numeric()
tryCatch({
  repeat {
    started <- proc.time()[["elapsed"]]
    run_once()
    durations <- c(durations, proc.time()[["elapsed"]] - started)
    if (sum(durations) >= 5) break
  }
  dbExecute(con, "PRAGMA enable_profiling = 'json'")
  dbExecute(con, paste("SET profiling_output =", dbQuoteString(con, profile_path)))
  dbExecute(con, paste("CREATE TEMP TABLE native_consumed AS", selected))
  dbExecute(con, "PRAGMA disable_profiling")
  got <- dbGetQuery(con, "SELECT count(*) AS n, count(*) FILTER (WHERE vals IS NULL) AS bad, sum(vals) AS total FROM native_consumed")
  stopifnot(got$n == n, got$bad == 0, is.finite(got$total),
            abs(got$total - expected) <= 1e-12 * max(1, abs(expected)))
  cat("METRIC", threads, length(durations), sum(durations), mean(durations) * 1000,
      setup_s, durations[[1L]], got$total, "\n", sep = "\t")
}, finally = dbDisconnect(con, shutdown = TRUE))
