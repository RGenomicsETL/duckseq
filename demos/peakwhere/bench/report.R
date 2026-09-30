# Shared tables for performance.Rmd and README.Rmd; no benchmark runs during rendering.
range_cell <- function(x, digits = 3L) {
  sprintf(paste0("%.", digits, "f [%." , digits, "f–%.", digits, "f]"), median(x), min(x), max(x))
}

headline <- function(results) {
  do.call(rbind, lapply(names(results), function(w) {
    receipt <- results[[w]]
    row <- data.frame(Workload = w)
    for (engine in c("wasm", "native-1t", "native-nt", "chipseeker")) {
      row[[engine]] <- if (receipt$status == "passed") {
        runs <- Filter(function(r) !r$warmup, receipt$runs)
        range_cell(vapply(runs, function(r) r$engines[[engine]]$seconds$total, 0))
      } else "not reported"
    }
    row
  }))
}

timing_table <- function(receipt) {
  runs <- Filter(function(r) !r$warmup, receipt$runs)
  do.call(rbind, lapply(names(runs[[1]]$engines), function(engine) {
    phases <- names(runs[[1]]$engines[[engine]]$seconds)
    data.frame(Engine = engine, Phase = phases,
      `Seconds: median [min–max]` = vapply(phases, function(phase) {
        range_cell(vapply(runs, function(r) r$engines[[engine]]$seconds[[phase]], 0))
      }, ""), check.names = FALSE)
  }))
}

memory_table <- function(receipt) {
  runs <- Filter(function(r) !r$warmup, receipt$runs)
  engines <- names(runs[[1]]$engines)
  data.frame(Engine = engines, `Peak RSS MiB: median [min–max]` = vapply(engines, function(engine) {
    if (engine == "wasm") return("not measured")
    range_cell(vapply(runs, function(r) r$engines[[engine]]$rss_kb / 1024, 0), 1L)
  }, ""), check.names = FALSE)
}

agreement_table <- function(receipt) {
  engines <- receipt$runs[[1]]$engines
  sql <- engines$wasm$counts_centre
  chip <- engines$chipseeker$counts_centre
  do.call(rbind, lapply(c(names(sql), "All"), function(label) {
    a <- if (label == "All") Reduce(`+`, lapply(sql, unlist)) else unlist(sql[[label]])
    b <- if (label == "All") Reduce(`+`, lapply(chip, unlist)) else unlist(chip[[label]])
    data.frame(Mark = label, Category = names(a), SQL = unname(a),
               ChIPseeker = unname(b[names(a)]), `ChIPseeker − SQL` = unname(b[names(a)] - a), check.names = FALSE)
  }))
}
