#!/usr/bin/env Rscript
Sys.setenv(OMP_NUM_THREADS = "1", OPENBLAS_NUM_THREADS = "1", MKL_NUM_THREADS = "1",
           BLIS_NUM_THREADS = "1", VECLIB_MAXIMUM_THREADS = "1", LC_ALL = "C",
           R_LIBS_USER = paste(c(file.path(getwd(), ".rlib"),
                                 file.path(getwd(), ".cache", "R", "library")),
                               collapse = .Platform$path.sep))

.libPaths(c(".rlib", ".cache/R/library", .libPaths()))
startup_args <- commandArgs(trailingOnly = TRUE)
ldzip_worker <- length(startup_args) >= 3L && startup_args[[1L]] == "--worker" &&
  startup_args[[3L]] == "ldzip"
if (!ldzip_worker) suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

root <- normalizePath(".", mustWork = TRUE)
if (basename(root) != "ldzip") stop("Run from demos/ldzip", call. = FALSE)
prefix <- file.path(root, "work", "derived", "region-4x")
protocol_file <- file.path(root, "NATIVE_PROTOCOL.md")
template_file <- file.path(root, "native_dense.sql")
native_file <- file.path(root, "native_dense.c")
extension_file <- Sys.getenv("DUCKTINYCC_EXTENSION",
  "/root/DuckTinyCC/build/release/ducktinycc.duckdb_extension")
output_dir <- Sys.getenv("NATIVE_OUT_DIR", file.path(root, "work", "perf", "native"))

read_templates <- function(path) {
  if (!file.exists(path)) stop("Missing native SQL templates: ", path, call. = FALSE)
  parts <- trimws(strsplit(paste(readLines(path, warn = FALSE), collapse = "\n"),
                            ";", fixed = TRUE)[[1L]])
  parts <- parts[nzchar(parts)]
  if (length(parts) != 2L || any(!grepl("^(WITH|SELECT)\\b", parts, ignore.case = TRUE)))
    stop("native_dense.sql must contain exactly two SELECT statements", call. = FALSE)
  parts
}

settings <- function(con, threads, temp_dir) {
  dbExecute(con, sprintf("SET threads = %d", threads))
  dbExecute(con, "SET memory_limit = '1GiB'")
  dbExecute(con, "SET max_temp_directory_size = '512MiB'")
  dbExecute(con, paste0("SET temp_directory = ", dbQuoteString(con, temp_dir)))
}

register_native <- function(con, source_path) {
  if (!file.exists(source_path)) stop("Missing native C source: ", source_path, call. = FALSE)
  source <- paste(readLines(source_path, warn = FALSE), collapse = "\n")
  sql <- paste0(
    "SELECT ok, code FROM tcc_module(mode := 'quick_compile', kind := 'aggregate', ",
    "symbol := 'ld_dense_column', sql_name := 'ld_dense_column', ",
    "return_type := 'f64[]', arg_types := ['i64','i64','i64','i64','i64'], source := ",
    dbQuoteString(con, source), ")")
  result <- dbGetQuery(con, sql)
  if (nrow(result) != 1L || !isTRUE(result$ok[[1L]])) {
    code <- if (nrow(result)) paste(result$code, collapse = " ") else "no registration result"
    stop("DuckTinyCC aggregate registration failed: ", code, call. = FALSE)
  }
  invisible(NULL)
}

scalar_consume <- function(con, n) {
  got <- dbGetQuery(con, paste0(
    "SELECT count(*) AS output_columns, coalesce(sum(len(vals)), 0) AS output_cells, ",
    "count(*) FILTER (WHERE vals IS NULL) AS null_columns, ",
    "coalesce(sum(list_sum(vals)), 0.0) AS checksum FROM dense_result"))
  if (got$output_columns[[1L]] != n || got$output_cells[[1L]] != as.double(n) * n ||
      got$null_columns[[1L]] != 0 || !is.finite(got$checksum[[1L]]))
    stop("SQL dense result failed shape/consumption checks", call. = FALSE)
  got
}

worker <- function(args) {
  if (length(args) != 7L) stop("Invalid internal worker arguments", call. = FALSE)
  engine <- args[[2L]]
  n <- as.integer(args[[3L]])
  bits <- as.integer(args[[4L]])
  threads <- as.integer(args[[5L]])
  seconds <- as.numeric(args[[6L]])
  stored_rows <- as.numeric(args[[7L]])
  profile_file <- normalizePath(args[[1L]], mustWork = FALSE)
  if (!engine %in% c("sql", "tinycc", "ldzip") || !n %in% c(1000L, 2000L, 4000L, 5000L) ||
      !bits %in% c(8L, 16L) || threads < 1L || !is.finite(seconds) || seconds < 5 ||
      !is.finite(stored_rows) || stored_rows < 0)
    stop("Invalid worker parameters", call. = FALSE)
  parquet <- sprintf("%s-b%d-parquet-rg262144-z9/ld.parquet", prefix, bits)
  parquet <- normalizePath(parquet, mustWork = TRUE)
  templates <- read_templates(template_file)
  scale <- 2^(bits - 1L) - 1L
  temp_dir <- paste0(profile_file, ".spill")
  dir.create(temp_dir, recursive = TRUE, showWarnings = FALSE)
  setup_start <- proc.time()[["elapsed"]]

  if (engine == "ldzip") {
    ld <- LDZipMatrix::LDZipMatrix(sprintf("%s-b%d", prefix, bits))
    if (dim(ld)[1L] < n || dim(ld)[2L] < n) stop("LDZip source is smaller than requested window")
    con <- NULL
    selected_sql <- NULL
  } else {
    con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
    settings(con, threads, temp_dir)
    if (engine == "tinycc") {
      if (!file.exists(extension_file)) stop("Missing local DuckTinyCC extension")
      dbExecute(con, paste("LOAD", dbQuoteString(con, normalizePath(extension_file))))
      register_native(con, native_file)
    }
    selected_sql <- templates[[match(engine, c("sql", "tinycc"))]]
    dbExecute(con, paste0("SET VARIABLE ld_path = ", dbQuoteString(con, parquet)))
    dbExecute(con, sprintf("SET VARIABLE matrix_n = %d", n))
    dbExecute(con, sprintf("SET VARIABLE quant_scale = %d", scale))
  }
  setup_s <- proc.time()[["elapsed"]] - setup_start

  run_sql <- function() {
    dbExecute(con, paste("CREATE TEMP TABLE dense_result AS", selected_sql))
    scalar_consume(con, n)
    dbExecute(con, "DROP TABLE dense_result")
    invisible(NULL)
  }
  run_ldzip <- function() {
    m <- LDZipMatrix::fetchLD(ld, seq_len(n), seq_len(n), types = "UNPHASED_R")
    checksum <- sum(m)
    if (length(m) != as.double(n) * n || !is.finite(checksum))
      stop("LDZip dense matrix failed full-consumption checks", call. = FALSE)
    rm(m)
    invisible(checksum)
  }
  run_one <- if (engine == "ldzip") run_ldzip else run_sql
  durations <- numeric()
  repeat {
    started <- proc.time()[["elapsed"]]
    run_one()
    durations <- c(durations, proc.time()[["elapsed"]] - started)
    if (sum(durations) >= seconds) break
  }

  profile_s <- 0
  profile_buffer <- NA_real_
  profile_spill <- NA_real_
  if (engine == "ldzip") {
    writeLines('{"profile_type":"not_applicable","reason":"LDZipMatrix R-matrix endpoint; no DuckDB profile"}',
               profile_file)
  } else {
    started <- proc.time()[["elapsed"]]
    dbExecute(con, "PRAGMA enable_profiling = 'json'")
    dbExecute(con, paste0("SET profiling_output = ", dbQuoteString(con, profile_file)))
    dbExecute(con, paste("CREATE TEMP TABLE dense_result AS", selected_sql))
    dbExecute(con, "PRAGMA disable_profiling")
    scalar_consume(con, n)
    dbExecute(con, "DROP TABLE dense_result")
    profile_s <- proc.time()[["elapsed"]] - started
    if (!file.exists(profile_file)) stop("DuckDB profiling did not create a profile")
  }
  output_cells <- as.double(n) * n
  output_bytes <- output_cells * 8
  db_version <- as.character(packageVersion("duckdb"))
  ldzip_version <- as.character(packageVersion("LDZipMatrix"))
  if (!is.null(con)) dbDisconnect(con, shutdown = TRUE)
  cat(paste(c("METRIC", format(setup_s, digits = 10), format(durations[[1L]], digits = 10),
              length(durations), format(sum(durations), digits = 10),
              format(mean(durations) * 1000, digits = 10), n, output_cells, output_bytes,
              stored_rows, profile_buffer, profile_spill, format(profile_s, digits = 10),
              db_version, ldzip_version), collapse = "\t"), "\n", sep = "")
}

parse_filter <- function(name, default, allowed) {
  value <- Sys.getenv(name, "")
  if (!nzchar(value)) return(default)
  parsed <- as.integer(strsplit(value, ",", fixed = TRUE)[[1L]])
  if (anyNA(parsed) || any(!parsed %in% allowed)) stop("Invalid ", name, " filter", call. = FALSE)
  parsed
}

sha256 <- function(path) {
  out <- system2("sha256sum", shQuote(path), stdout = TRUE, stderr = TRUE)
  if (!length(out) || !grepl("^[[:xdigit:]]{64} ", out[[1L]])) stop("sha256sum failed for ", path)
  sub(" .*", "", out[[1L]])
}

profile_value <- function(path, key) {
  if (!file.exists(path)) return(NA_real_)
  x <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(x)) return(NA_real_)
  find <- function(value) {
    if (!is.list(value)) return(NULL)
    if (!is.null(names(value)) && key %in% names(value)) return(value[[key]])
    for (item in value) {
      answer <- find(item)
      if (!is.null(answer)) return(answer)
    }
    NULL
  }
  answer <- find(x)
  if (is.null(answer)) NA_real_ else suppressWarnings(as.numeric(answer[[1L]]))
}

main <- function() {
  engines <- strsplit(Sys.getenv("NATIVE_ENGINES", "sql,tinycc,ldzip"), ",", fixed = TRUE)[[1L]]
  if (any(!engines %in% c("sql", "tinycc", "ldzip")) || !length(engines))
    stop("NATIVE_ENGINES must select sql,tinycc,ldzip", call. = FALSE)
  sizes <- parse_filter("NATIVE_SIZES", c(1000L, 2000L, 4000L), c(1000L, 2000L, 4000L, 5000L))
  bits <- parse_filter("NATIVE_BITS", c(8L, 16L), c(8L, 16L))
  threads <- parse_filter("NATIVE_THREADS", c(1L, 4L), c(1L, 4L))
  reps <- as.integer(Sys.getenv("NATIVE_REPS", "3"))
  seconds <- as.numeric(Sys.getenv("NATIVE_SECONDS", "5"))
  if (is.na(reps) || reps < 1L || !is.finite(seconds) || seconds < 5)
    stop("NATIVE_REPS must be positive and NATIVE_SECONDS at least 5", call. = FALSE)
  overrides <- c("NATIVE_SIZES", "NATIVE_BITS", "NATIVE_ENGINES", "NATIVE_THREADS",
                 "NATIVE_REPS", "NATIVE_SECONDS")
  used_overrides <- overrides[nzchar(Sys.getenv(overrides, unset = ""))]
  templates <- read_templates(template_file)
  if (!file.exists(native_file)) stop("Missing native C source: ", native_file, call. = FALSE)
  if (!file.exists(extension_file)) stop("Missing local DuckTinyCC extension: ", extension_file)
  if (!file.exists("/usr/bin/time") || !file.exists("/usr/bin/timeout"))
    stop("/usr/bin/time and /usr/bin/timeout are required", call. = FALSE)

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  for (subdir in c("profiles", "logs")) {
    path <- file.path(output_dir, subdir)
    dir.create(path, recursive = TRUE, showWarnings = FALSE)
    unlink(list.files(path, full.names = TRUE, all.files = TRUE, no.. = TRUE), recursive = TRUE)
  }
  source_rows <- list()
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  for (b in bits) for (n in sizes) {
    path <- normalizePath(sprintf("%s-b%d-parquet-rg262144-z9/ld.parquet", prefix, b), mustWork = TRUE)
    source_rows[[paste(n, b, sep = "-")]] <- dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM read_parquet('%s') WHERE i BETWEEN 1 AND %d AND j BETWEEN 1 AND %d",
      gsub("'", "''", path, fixed = TRUE), n, n))$n[[1L]]
  }
  dbDisconnect(con, shutdown = TRUE)

  env_lines <- c(
    "Protocol: demos/ldzip/NATIVE_PROTOCOL.md",
    paste("Complete dimension ladder:", if (length(used_overrides)) "NO (explicit scope override)" else "YES"),
    paste("Overrides:", if (length(used_overrides)) paste(used_overrides, collapse = ",") else "none"),
    paste("Engines:", paste(engines, collapse = ",")), paste("Sizes:", paste(sizes, collapse = ",")),
    paste("Bits:", paste(bits, collapse = ",")), paste("SQL threads:", paste(threads, collapse = ",")),
    paste("Repetitions:", reps), paste("Minimum measured seconds/process:", seconds),
    "Per-process timeout: 60 seconds (external /usr/bin/timeout)",
    "DuckDB limits: memory_limit=1GiB; max_temp_directory_size=512MiB",
    "RSS ceiling bytes: 512*1024^2 + 3*32*n*n; equal for all engines at each n",
    paste("R:", as.character(getRversion())), paste("DuckDB R package:", packageVersion("duckdb")),
    paste("LDZipMatrix:", packageVersion("LDZipMatrix")),
    paste("DuckTinyCC extension:", extension_file), paste("DuckTinyCC SHA256:", sha256(extension_file)),
    paste("DuckDB CLI version (context only):", if (file.exists(".cache/duckdb"))
      paste(system2(".cache/duckdb", "--version", stdout = TRUE), collapse = " ") else "unavailable"),
    paste("OS:", paste(Sys.info()[c("sysname", "release", "machine")], collapse = " ")),
    paste("CPU:", paste(grep("^(model name|Hardware)", readLines("/proc/cpuinfo", warn = FALSE),
                                value = TRUE)[1L], collapse = "")),
    paste("Thread controls:", "OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 BLIS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1"),
    "DuckDB endpoints: SQL-resident j,vals DOUBLE[]; LDZip endpoint: returned R matrix",
    paste("Input file:", "work/derived/region-4x-b{8,16}-parquet-rg262144-z9/ld.parquet"),
    paste("SQL templates:\n", paste(templates, collapse = ";\n")),
    paste("Template SHA256:", sha256(template_file)), paste("C source SHA256:", sha256(native_file)))
  for (b in bits) {
    p <- sprintf("%s-b%d-parquet-rg262144-z9/ld.parquet", prefix, b)
    v <- sprintf("%s-b%d-parquet-rg262144-z9/variants.parquet", prefix, b)
    env_lines <- c(env_lines, paste("LD input SHA256 b", b, ":", sha256(p)),
                   paste("Variants input SHA256 b", b, ":", sha256(v)))
  }
  writeLines(env_lines, file.path(output_dir, "environment.txt"))

  raw_path <- file.path(output_dir, "raw.tsv")
  columns <- c("engine", "n", "bits", "threads", "replicate", "status", "error",
               "setup_s", "first_s", "iterations", "measured_s", "mean_ms", "process_elapsed_s",
               "peak_rss_kb", "peak_rss_bytes", "rss_ceiling_bytes", "output_columns", "output_cells",
               "output_bytes", "selected_stored_rows", "profile_buffer_bytes", "profile_spill_bytes",
               "spill_limit_bytes", "profile_s", "profile_path", "log_path", "duckdb_r_version",
               "ldzip_version", "override_label")
  write.table(as.data.frame(setNames(replicate(length(columns), character(), simplify = FALSE), columns)),
              raw_path, sep = "\t", quote = FALSE, row.names = FALSE)
  rows <- list()
  rscript <- file.path(R.home("bin"), "Rscript")
  script <- normalizePath("measure_native.R", mustWork = TRUE)
  spill_limit <- 512 * 1024^2
  idx <- 0L
  case_threads <- unique(c(threads, if ("ldzip" %in% engines) 1L))
  for (n in sizes) for (b in bits) for (thread in case_threads) for (replicate in seq_len(reps)) {
    engine_order <- if (replicate %% 2L) engines else rev(engines)
    for (engine in engine_order) {
      if (engine == "ldzip" && thread != 1L) next
      if (engine != "ldzip" && !thread %in% threads) next
      idx <- idx + 1L
      slug <- sprintf("%s-n%d-b%d-t%d-r%d", engine, n, b, thread, replicate)
      profile_path <- file.path(output_dir, "profiles", paste0(slug, ".json"))
      log_path <- file.path(output_dir, "logs", paste0(slug, ".log"))
      time_path <- file.path(output_dir, "logs", paste0(slug, ".time"))
      log_con <- file(log_path, open = "wt")
      close(log_con)
      args <- c("60s", "/usr/bin/time", "-f", shQuote("%e\t%M"), "-o", shQuote(time_path),
                shQuote(rscript), "--vanilla", shQuote(script), "--worker", shQuote(profile_path),
                shQuote(engine), n, b, thread, seconds, source_rows[[paste(n, b, sep = "-")]])
      child_env <- c(paste0("R_LIBS_USER=", shQuote(Sys.getenv("R_LIBS_USER"))),
                     "OMP_NUM_THREADS=1", "OPENBLAS_NUM_THREADS=1", "MKL_NUM_THREADS=1",
                     "BLIS_NUM_THREADS=1", "VECLIB_MAXIMUM_THREADS=1", "LC_ALL=C",
                     paste0("DUCKTINYCC_EXTENSION=", shQuote(extension_file)))
      status_code <- system2("/usr/bin/timeout", args, stdout = log_path, stderr = log_path,
                             env = child_env)
      log_oversized <- file.info(log_path)$size > 10 * 1024^2
      if (log_oversized) {
        writeBin(readBin(log_path, "raw", n = 10 * 1024^2), log_path)
        status_code <- 1L
      }
      profile_oversized <- file.exists(profile_path) && file.info(profile_path)$size > 10 * 1024^2
      if (profile_oversized) {
        writeBin(readBin(profile_path, "raw", n = 10 * 1024^2), profile_path)
        status_code <- 1L
      }
      log_lines <- readLines(log_path, warn = FALSE)
      metric_line <- grep("^METRIC\\t", log_lines, value = TRUE)
      fields <- if (length(metric_line)) strsplit(metric_line[[length(metric_line)]], "\t", fixed = TRUE)[[1L]] else character()
      time_line <- if (file.exists(time_path)) tail(readLines(time_path, warn = FALSE), 1L) else character()
      time_fields <- if (length(time_line)) strsplit(time_line[[1L]], "\t", fixed = TRUE)[[1L]] else character()
      process_elapsed <- if (length(time_fields) >= 2L) suppressWarnings(as.numeric(time_fields[[1L]])) else NA_real_
      rss_kb <- if (length(time_fields) >= 2L) suppressWarnings(as.numeric(time_fields[[2L]])) else NA_real_
      ceiling <- 512 * 1024^2 + 3 * 32 * as.double(n) * n
      buffer <- profile_value(profile_path, "system_peak_buffer_memory")
      spill <- profile_value(profile_path, "system_peak_temp_dir_size")
      expected_sql_profile <- engine != "ldzip"
      good <- status_code == 0L && !log_oversized && !profile_oversized &&
        length(fields) == 15L && is.finite(rss_kb) && file.exists(profile_path)
      err <- ""
      if (!good) {
        recent <- tail(log_lines, 8L)
        err <- paste(if (status_code == 124L) "60-second timeout" else paste("worker exit", status_code),
                     paste(recent, collapse = " | "))
      } else if (rss_kb * 1024 > ceiling) {
        good <- FALSE
        err <- "peak RSS exceeded declared ceiling"
      } else if (expected_sql_profile && (!is.finite(buffer) || !is.finite(spill))) {
        good <- FALSE
        err <- "DuckDB profile missing peak-buffer or spill metrics"
      } else if (expected_sql_profile && spill > spill_limit) {
        good <- FALSE
        err <- "DuckDB spill exceeded declared 512 MiB limit"
      }
      if (length(fields) == 15L) {
        values <- suppressWarnings(as.numeric(fields[2:13]))
        duckdb_r <- fields[[14L]]
        ldzip_version <- fields[[15L]]
      } else {
        values <- rep(NA_real_, 12L)
        duckdb_r <- as.character(packageVersion("duckdb"))
        ldzip_version <- as.character(packageVersion("LDZipMatrix"))
      }
      row <- data.frame(engine = engine, n = n, bits = b, threads = thread, replicate = replicate,
        status = if (good) "PASS" else "FAIL", error = err,
        setup_s = values[[1L]], first_s = values[[2L]], iterations = values[[3L]],
        measured_s = values[[4L]], mean_ms = values[[5L]], process_elapsed_s = process_elapsed,
        peak_rss_kb = rss_kb, peak_rss_bytes = rss_kb * 1024, rss_ceiling_bytes = ceiling,
        output_columns = values[[6L]], output_cells = values[[7L]], output_bytes = values[[8L]],
        selected_stored_rows = values[[9L]], profile_buffer_bytes = buffer, profile_spill_bytes = spill,
        spill_limit_bytes = spill_limit, profile_s = values[[12L]], profile_path = profile_path,
        log_path = log_path, duckdb_r_version = duckdb_r, ldzip_version = ldzip_version,
        override_label = if (length(used_overrides)) "SCOPE_OVERRIDE" else "FULL_PROTOCOL",
        stringsAsFactors = FALSE)
      rows[[idx]] <- row
      write.table(row, raw_path, sep = "\t", quote = TRUE, row.names = FALSE,
                  col.names = FALSE, append = TRUE)
      cat(slug, row$status, sprintf("%.2f ms %.1f MiB", row$mean_ms, row$peak_rss_bytes / 1024^2), "\n")
      flush.console()
    }
  }
  raw <- do.call(rbind, rows)
  keys <- unique(raw[c("engine", "n", "bits", "threads")])
  summaries <- lapply(seq_len(nrow(keys)), function(i) {
    key <- keys[i, , drop = FALSE]
    x <- raw[raw$engine == key$engine & raw$n == key$n & raw$bits == key$bits &
               raw$threads == key$threads, , drop = FALSE]
    successful <- x$status == "PASS" & is.finite(x$mean_ms)
    means <- x$mean_ms[successful]
    status <- if (nrow(x) == 3L && all(successful) && all(x$measured_s >= 5)) "PASS" else
      if (nrow(x) < 3L && all(successful)) "SMOKE_ONLY" else "FAIL"
    data.frame(engine = key$engine, n = key$n, bits = key$bits, threads = key$threads,
      processes = nrow(x), successful_processes = sum(successful),
      median_process_mean_ms = if (length(means)) median(means) else NA_real_,
      min_process_mean_ms = if (length(means)) min(means) else NA_real_,
      max_process_mean_ms = if (length(means)) max(means) else NA_real_,
      median_first_s = if (any(is.finite(x$first_s))) median(x$first_s, na.rm = TRUE) else NA_real_,
      max_peak_rss_bytes = if (any(is.finite(x$peak_rss_bytes))) max(x$peak_rss_bytes, na.rm = TRUE) else NA_real_,
      rss_ceiling_bytes = unique(x$rss_ceiling_bytes)[[1L]],
      max_profile_spill_bytes = if (any(is.finite(x$profile_spill_bytes))) max(x$profile_spill_bytes, na.rm = TRUE) else NA_real_,
      cell_status = status, stringsAsFactors = FALSE)
  })
  write.table(do.call(rbind, summaries), file.path(output_dir, "summary.tsv"), sep = "\t",
              quote = FALSE, row.names = FALSE)
  cat("Native measurements written to ", output_dir, "\n", sep = "")
  if (any(raw$status == "FAIL")) quit(save = "no", status = 1L)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) && args[[1L]] == "--worker") {
    worker(args[-1L])
  } else {
    main()
  }
}
