#!/usr/bin/env Rscript
# Exact-value and failure checks are separate from measured processes.
source("measure_native.R")
templates <- read_templates(template_file)
temp_dir <- tempfile("native-parity-spill-")
dir.create(temp_dir)
results <- list()

for (bits in c(8L, 16L)) for (n in c(1000L, 2000L, 4000L, 5000L)) for (threads in c(1L, 4L)) {
  path <- normalizePath(sprintf("%s-b%d-parquet-rg262144-z9/ld.parquet", prefix, bits))
  scale <- 2^(bits - 1L) - 1L
  for (engine in c("tinycc", "sql")) {
    con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
    outcome <- tryCatch({
      settings(con, threads, temp_dir)
      if (engine == "tinycc") {
        dbExecute(con, paste("LOAD", dbQuoteString(con, normalizePath(extension_file))))
        register_native(con, native_file)
      }
      dbExecute(con, paste("SET VARIABLE ld_path =", dbQuoteString(con, path)))
      dbExecute(con, sprintf("SET VARIABLE matrix_n = %d", n))
      dbExecute(con, sprintf("SET VARIABLE quant_scale = %d", scale))
      domain <- dbGetQuery(con, sprintf(paste0(
        "SELECT count(*) AS rows, count(DISTINCT (i,j)) AS unique_cells, ",
        "count(*) FILTER (WHERE r_q IS NULL OR abs(r_q::BIGINT)>%d) AS bad_values ",
        "FROM read_parquet(%s) WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d"),
        scale, dbQuoteString(con, path), n, n))
      stopifnot(domain$rows == domain$unique_cells, domain$bad_values == 0)
      selected <- templates[[match(engine, c("sql", "tinycc"))]]
      dbExecute(con, paste("CREATE TEMP TABLE dense_result AS", selected))
      scalar_consume(con, n)
      differences <- dbGetQuery(con, sprintf(paste0(
        "WITH cells AS (SELECT j, unnest(vals) AS r, unnest(range(1,%d+1)) AS i FROM dense_result), ",
        "reference AS (SELECT i,j,CAST(CAST(r_q AS REAL)/%d AS REAL)::DOUBLE AS r ",
        "FROM read_parquet(%s) WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d) ",
        "SELECT count(*) AS cells, count(*) FILTER (WHERE c.r IS DISTINCT FROM ",
        "CASE WHEN c.i=c.j THEN 1::DOUBLE ELSE coalesce(ref.r,0::DOUBLE) END) AS differences ",
        "FROM cells c LEFT JOIN reference ref ON c.i=ref.i AND c.j=ref.j"),
        n, scale, dbQuoteString(con, path), n, n))
      stopifnot(differences$cells == as.double(n) * n, differences$differences == 0)
      if (n == 1000L && threads == 1L) {
        columns <- dbGetQuery(con, "SELECT vals FROM dense_result ORDER BY j")$vals
        actual <- matrix(unlist(columns, use.names = FALSE), n, n)
        ld <- LDZipMatrix::LDZipMatrix(sprintf("%s-b%d", prefix, bits))
        expected <- LDZipMatrix::fetchLD(ld, seq_len(n), seq_len(n), types = "UNPHASED_R")
        stopifnot(identical(unname(actual), unname(expected)))
      }
      list(status = "PASS", error = "")
    }, error = function(e) {
      message <- conditionMessage(e)
      if (!grepl("Out of Memory|maximum temporary directory size", message, ignore.case = TRUE)) stop(e)
      list(status = "RESOURCE_FAIL", error = gsub("[\r\n\t]+", " ", message))
    }, finally = dbDisconnect(con, shutdown = TRUE))
    results[[length(results) + 1L]] <- data.frame(engine, bits, n, threads,
      status = outcome$status, error = outcome$error)
    cat(outcome$status, engine, "bits", bits, "n", n, "threads", threads,
        "cells", as.double(n) * n, "\n")
    flush.console()
  }
}

# A seeded empty column is valid; rejected native parameters must remain visible.
con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
tryCatch({
  dbExecute(con, paste("LOAD", dbQuoteString(con, normalizePath(extension_file))))
  register_native(con, native_file)
  cases <- dbGetQuery(con, paste0(
    "SELECT ld_dense_column(0::BIGINT,1::BIGINT,0::BIGINT,4::BIGINT,127::BIGINT) AS empty_col, ",
    "ld_dense_column(5::BIGINT,1::BIGINT,1::BIGINT,4::BIGINT,127::BIGINT) IS NULL AS bad_row, ",
    "ld_dense_column(1::BIGINT,1::BIGINT,128::BIGINT,4::BIGINT,127::BIGINT) IS NULL AS bad_q, ",
    "ld_dense_column(1::BIGINT,1::BIGINT,1::BIGINT,4::BIGINT,0::BIGINT) IS NULL AS bad_scale"))
  stopifnot(identical(cases$empty_col[[1L]], c(1,0,0,0)), cases$bad_row, cases$bad_q, cases$bad_scale)
  dbExecute(con, paste0("CREATE TEMP TABLE dense_result AS SELECT 1 AS j, ",
    "ld_dense_column(5::BIGINT,1::BIGINT,1::BIGINT,4::BIGINT,127::BIGINT) AS vals"))
  stopifnot(inherits(tryCatch(scalar_consume(con, 1L), error = identity), "error"))
  dbExecute(con, "DROP TABLE dense_result")
  dbExecute(con, paste("SET VARIABLE ld_path =", dbQuoteString(con, path)))
  dbExecute(con, "SET VARIABLE matrix_n = 4")
  dbExecute(con, sprintf("SET VARIABLE quant_scale = %d", scale))
  dbExecute(con, paste("CREATE TEMP TABLE dense_result AS", templates[[2L]]))
  mutations <- dbGetQuery(con, paste0("SELECT count(*) AS n FROM dense_result WHERE ",
    "list_transform(vals, (v,i) -> CASE WHEN i=j THEN 0.0 ELSE v END) IS DISTINCT FROM vals"))$n
  stopifnot(mutations == 4L)
  cat("PASS seeded-empty diagonal, malformed-input rejection, consumer NULL failure and diagonal mutation\n")
}, finally = {
  dbDisconnect(con, shutdown = TRUE)
  unlink(temp_dir, recursive = TRUE)
})

out <- file.path(root, "work", "perf", "native-admission.tsv")
dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
write.table(do.call(rbind, results), out, sep = "\t", row.names = FALSE, quote = TRUE)
cat("Admission statuses:", out, "(resource failures are retained, not parity passes)\n")
