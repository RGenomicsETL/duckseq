# Run from the repository root: Rscript bench/run.R W1|W2
# Timing receipts are published only after the workload's correctness gates pass.
args <- commandArgs(TRUE)
workload <- if (length(args) > 0L) args[1] else "W1"
stopifnot(workload %in% c("W1", "W2"))
limit <- 600 # seconds per engine run, including warm-up
oracle_limit <- if (workload == "W1") limit else 120
scratch <- tempfile("duckpeakwhere-bench-", tmpdir = "/tmp")
dir.create(scratch)

run <- function(command, args, timeout = limit) {
  result <- processx::run(command, args, timeout = timeout, error_on_status = FALSE, cleanup_tree = TRUE)
  if (result$status != 0L || result$timeout) {
    stop(paste(command, paste(args, collapse = " "), "\nstatus:", result$status,
               "timeout:", result$timeout, "\n", result$stderr, result$stdout), call. = FALSE)
  }
  result
}
read_result <- function(path) jsonlite::read_json(path, simplifyVector = FALSE)
write_result <- function(value, path) jsonlite::write_json(value, path, auto_unbox = TRUE, pretty = TRUE, digits = NA)
sha256 <- function(paths) {
  setNames(as.list(sub(" .*", "", strsplit(run("sha256sum", paths)$stdout, "\n")[[1]])), paths)
}
canonical <- function(counts) {
  labels <- sort(names(counts))
  categories <- c("promoter", "utr5", "utr3", "exon", "intron", "intergenic")
  unlist(lapply(counts[labels], function(row) {
    stopifnot(setequal(names(row), categories))
    setNames(as.numeric(unlist(row[categories])), categories)
  }))
}

one_run <- function(iteration, input, expected) {
  prefix <- file.path(scratch, paste0("run-", iteration))
  browser_file <- paste0(prefix, "-wasm.json")
  browser <- processx::process$new("node", c("bench/browser.mjs", input, browser_file),
    stdin = "|", stdout = paste0(prefix, "-browser.stdout"), stderr = paste0(prefix, "-browser.stderr"),
    cleanup = TRUE, cleanup_tree = TRUE)
  on.exit(if (browser$is_alive()) browser$kill_tree())
  deadline <- Sys.time() + limit
  while (!file.exists(browser_file)) {
    if (!browser$is_alive() || Sys.time() > deadline) {
      stop(paste("wasm failed or exceeded", limit, "seconds:",
        paste(readLines(paste0(prefix, "-browser.stderr"), warn = FALSE), collapse = "\n")), call. = FALSE)
    }
    Sys.sleep(0.05)
  }
  wasm <- read_result(browser_file)
  wasm$trace <- wasm$request <- NULL
  records <- list(wasm = wasm)
  for (engine in c("native-1t", "native-nt")) {
    output <- paste0(prefix, "-", engine, ".json")
    run("node", c("bench/native.mjs", browser_file, engine, output))
    records[[engine]] <- read_result(output)
    stopifnot(identical(records[[engine]]$sql_sha256, wasm$sql_sha256))
  }
  browser$write_input("close\n")
  browser$wait(10000)
  stopifnot(!browser$is_alive(), browser$get_exit_status() == 0L)
  reference <- if (is.null(expected)) wasm$counts_centre else expected
  for (engine in names(records)) {
    stopifnot(identical(canonical(records[[engine]]$counts_centre), canonical(reference)),
              identical(records[[engine]]$unmatched, wasm$unmatched))
    if (workload == "W1") stopifnot(all(unlist(records[[engine]]$unmatched) == 0))
  }
  output <- paste0(prefix, "-chipseeker.json")
  time_file <- paste0(output, ".time")
  start <- unname(proc.time()["elapsed"])
  log <- run("/usr/bin/time", c("-v", "-o", time_file, "Rscript", "bench/chipseeker.R", input, output))
  wall <- unname(proc.time()["elapsed"]) - start
  chip <- read_result(output)
  chip$seconds$process_wall <- wall
  chip$time_v <- paste(readLines(time_file), collapse = "\n")
  chip$rss_kb <- as.numeric(sub(".*Maximum resident set size \\(kbytes\\): ([0-9]+).*", "\\1", chip$time_v))
  chip$stderr <- log$stderr
  labels <- sort(names(wasm$counts_centre))
  input_n <- vapply(wasm$counts_centre[labels], function(x) sum(unlist(x)), 0) + unlist(wasm$unmatched[labels])
  stopifnot(identical(as.numeric(unlist(chip$input_n[labels])), unname(input_n)))
  records$chipseeker <- chip
  list(iteration = iteration, warmup = iteration == 0L, engines = records)
}

benchmark <- function() {
  staging <- run("node", c("bench/stage.mjs", workload), timeout = 1830)$stdout
  directory <- if (workload == "W1") "examples" else "bench/.cache/W2"
  annotation <- if (workload == "W1") "gencode.vM25.basic.chr19.gff3.gz" else "gencode.vM25.basic.annotation.gff3.gz"
  peaks <- sort(list.files(directory, pattern = "\\.narrowPeak\\.gz$", full.names = TRUE))
  stopifnot(length(peaks) == 5L)
  labels <- vapply(strsplit(basename(peaks), "_", fixed = TRUE), `[`, "", 2L)
  request <- list(annotation = file.path(directory, annotation), peaks = data.frame(url = peaks, label = labels))
  input <- file.path(scratch, "request.json")
  write_result(request, input)
  expected <- NULL
  if (workload == "W1") {
    expected <- read_result("test/fixtures/thymus-expected.json")$counts_centre
    stopifnot(sum(canonical(expected)) == 7220)
    fixture_hash <- sha256("test/fixtures/thymus-expected.json")
    oracle_log <- run("Rscript", "test/oracle.R")$stdout
    stopifnot(identical(fixture_hash, sha256("test/fixtures/thymus-expected.json")))
    oracle <- list(status = "passed", limit_seconds = oracle_limit, fixture_sha256 = fixture_hash, log = oracle_log)
  } else {
    oracle_output <- file.path(scratch, "oracle.json")
    oracle_args <- c("test/oracle.R", request$annotation, directory, oracle_output)
    cat("W2 independent oracle; limit", oracle_limit, "seconds\n")
    probe <- processx::run("Rscript", oracle_args, timeout = oracle_limit,
                          error_on_status = FALSE, cleanup_tree = TRUE)
    oracle <- list(status = if (probe$timeout) "timeout" else "passed", limit_seconds = oracle_limit,
                   command = paste("Rscript", paste(oracle_args, collapse = " ")),
                   exit_status = probe$status, log = probe$stdout, stderr = probe$stderr)
    if (!probe$timeout) {
      if (probe$status != 0L) stop(paste(oracle$command, "exit", probe$status, probe$stderr), call. = FALSE)
      expected <- read_result(oracle_output)$counts_centre
    }
  }
  write_result(oracle, file.path(scratch, "oracle-status.json"))
  runs <- lapply(0:5, function(i) {
    cat(workload, if (i == 0) "warm-up" else paste("run", i), "\n")
    flush.console()
    one_run(i, input, expected)
  })
  for (r in runs) for (engine in names(r$engines)) {
    stopifnot(identical(canonical(r$engines[[engine]]$counts_centre),
                        canonical(runs[[1]]$engines[[engine]]$counts_centre)))
    field <- if (engine == "chipseeker") "dropped" else "unmatched"
    stopifnot(identical(r$engines[[engine]][[field]], runs[[1]]$engines[[engine]][[field]]))
  }
  list(status = "passed", input_sha256 = sha256(c(request$annotation, peaks)), staging = staging,
    settings = list(promoter = c(1000, 1000), mode = "centre", proteinCodingOnly = FALSE,
                    warmup = 1L, repetitions = 5L, engine_limit_seconds = limit),
    oracle = oracle,
    gate = paste(if (workload == "W1") "Every SQL run exactly matches thymus-expected.json." else
      if (is.null(expected)) "All SQL runs agree exactly; the independent oracle timed out." else
        "All SQL runs agree exactly with each other and the independent oracle.",
      "Identical SQL hashes across engines; ChIPseeker counts stable and input totals verified."),
    runs = runs)
}

result_file <- "benchmarks/results.json"
results <- if (file.exists(result_file)) read_result(result_file) else list()
outcome <- tryCatch(benchmark(), error = function(e) list(status = "failed", failure = conditionMessage(e),
  engine_limit_seconds = limit, oracle_limit_seconds = oracle_limit,
  skipped = "The workload stopped at this failure; no timings are published for it."))
if (file.exists(file.path(scratch, "oracle-status.json"))) {
  outcome$oracle <- read_result(file.path(scratch, "oracle-status.json"))
}
outcome$date <- format(Sys.time(), tz = "UTC", usetz = TRUE)
outcome$environment <- list(cpu = run("lscpu", character())$stdout, os = readLines("/etc/os-release"),
  kernel = run("uname", "-a")$stdout, node = run("node", "--version")$stdout,
  duckdb_wasm = read_result("node_modules/@duckdb/duckdb-wasm/package.json")$version,
  revision = trimws(run("git", c("rev-parse", "HEAD"))$stdout),
  source_sha256 = sha256(c("src/annotate.js", "test/oracle.R",
    list.files("bench", pattern = "\\.(R|mjs|html|json)$", full.names = TRUE))),
  manifest = read_result("bench/manifest.json"),
  duckhts = read_result("bench/manifest.json")$native, wasm_manifest = read_result("duckhts-manifest.json"))
results[[workload]] <- outcome
write_result(results, result_file)
if (outcome$status == "failed") {
  cat(outcome$failure, "\nFailure receipt:", result_file, "\n")
  quit(status = 1L)
}
cat("All gates passed. Receipts:", result_file, "\n")
unlink(scratch, recursive = TRUE)
