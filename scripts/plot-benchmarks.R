#!/usr/bin/env Rscript
# Render committed measurement receipts; this script does not run benchmark engines.
xml <- function(x) {
  x <- gsub("&","&amp;",x,fixed=TRUE)
  x <- gsub("<","&lt;",x,fixed=TRUE)
  gsub(">","&gt;",x,fixed=TRUE)
}
chart <- function(data, file, title, unit, xlabel, note) {
  stopifnot(all(c("series","x","y","lo","hi") %in% names(data)))
  labels <- unique(data$series)
  colours <- c("#8f6200","#2458a6","#1b744a","#ad3028","#64448e")
  xvalues <- sort(unique(data$x))
  ymax <- max(data$hi,na.rm=TRUE)*1.16
  xp <- function(x) 78+(x-min(xvalues))/max(1,diff(range(xvalues)))*400
  yp <- function(y) 315-y/ymax*210
  svg <- c('<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="title desc" viewBox="0 0 550 440">',
    sprintf('<title id="title">%s</title><desc id="desc">%s</desc>',xml(title),xml(note)),
    '<rect width="550" height="440" fill="#f2f5f4"/>',
    '<g font-family="system-ui,sans-serif" fill="#14202b" font-size="17">',
    sprintf('<text x="24" y="30" font-size="21" font-weight="650">%s</text>',xml(title)),
    sprintf('<text x="24" y="57" font-size="15">%s</text>',xml(unit)))
  ticks <- pretty(c(0,ymax),n=4)
  for (tick in ticks[ticks>=0 & ticks<=ymax]) svg <- c(svg,
    sprintf('<path d="M78 %.2f H498" stroke="#cbd5d9"/>',yp(tick)),
    sprintf('<text x="65" y="%.2f" text-anchor="end" font-size="15">%s</text>',yp(tick)+5,format(tick,trim=TRUE)))
  for (x in xvalues) svg <- c(svg,
    sprintf('<text x="%.2f" y="341" text-anchor="middle" font-size="15">%s</text>',xp(x),format(x,trim=TRUE)))
  svg <- c(svg,sprintf('<text x="285" y="368" text-anchor="middle">%s</text>',xml(xlabel)))
  for (i in seq_along(labels)) {
    d <- data[data$series==labels[[i]],,drop=FALSE]
    d <- d[order(d$x),,drop=FALSE]
    pass <- is.finite(d$y)
    colour <- colours[[i]]
    if (sum(pass)>1) svg <- c(svg,sprintf('<polyline fill="none" stroke="%s" stroke-width="2.5" points="%s"/>',
      colour,paste(sprintf("%.2f,%.2f",xp(d$x[pass]),yp(d$y[pass])),collapse=" ")))
    for (j in which(pass)) svg <- c(svg,
      sprintf('<path d="M%.2f %.2f V%.2f M%.2f %.2f h10 M%.2f %.2f h10" stroke="%s" stroke-width="1.5"/>',
        xp(d$x[j]),yp(d$lo[j]),yp(d$hi[j]),xp(d$x[j])-5,yp(d$lo[j]),xp(d$x[j])-5,yp(d$hi[j]),colour),
      sprintf('<circle cx="%.2f" cy="%.2f" r="4.5" fill="%s"/>',xp(d$x[j]),yp(d$y[j]),colour))
    for (j in which(!pass)) svg <- c(svg,
      sprintf('<text x="%.2f" y="%.2f" fill="#ad3028" text-anchor="middle" font-size="15">× fail</text>',
        xp(d$x[j]),82+i*15))
    svg <- c(svg,sprintf('<path d="M%d %d h20" stroke="%s" stroke-width="3"/><text x="%d" y="%d" font-size="14">%s</text>',
      24+((i-1)%%2)*260,395+((i-1)%/%2)*21,colour,50+((i-1)%%2)*260,400+((i-1)%/%2)*21,xml(labels[[i]])))
  }
  svg <- c(svg,'</g></svg>')
  writeLines(svg,file)
}
dir.create("site/assets/charts",showWarnings=FALSE)

# Synthetic AIE CLI measurements, kept separate from resident-engine timings.
aie <- read.delim("demos/aie/evidence/benchmark/raw.tsv")
stopifnot(all(aie$status=="PASS"),all(aie$measured_s>=5))
for (op in c("region","junction","prepare")) for (metric in c("latency","rss")) {
  raw <- subset(aie,operation==op)
  groups <- split(raw,interaction(raw$engine,raw$threads,raw$cells,drop=TRUE))
  data <- do.call(rbind,lapply(groups,function(d) {
    vals <- if(metric=="latency")d$elapsed_s*1000 else d$peak_rss_bytes/1024^2
    data.frame(series=paste(if(d$engine[[1]]=="gravlax")"Gravlax"else"DuckDB SQL",paste0(d$threads[[1]],"t")),
      x=d$cells[[1]],y=if(metric=="latency")median(vals)else max(vals),lo=min(vals),hi=max(vals))
  }))
  chart(data,paste0("site/assets/charts/aie-",op,"-",metric,".svg"),
    paste(tools::toTitleCase(op),if(metric=="latency")"CLI latency"else"peak memory"),
    if(metric=="latency")"Milliseconds / fresh CLI invocation · lower is better"else"Whole-CLI peak RSS (MiB) · lower is better",
    "Distinct synthetic cells (1× / 2× / 4×)",
    "Synthetic 120-base reference, three batches per point; every batch has at least five measured seconds. Latency points are medians of batch means; whiskers are ranges. Counts exactly match Gravlax. Not a public-transcriptome timing verdict.")
}

real <- read.delim("demos/aie/evidence/real/raw.tsv")
for(op in c("prepare","region-full","region-window")) for(threads in c(1,4)) for(metric in c("latency","rss")) {
  d <- real[real$threads==threads & (real$operation==op | startsWith(real$operation,paste0(op,"-"))),,drop=FALSE]
  groups <- split(d,interaction(d$engine,d$operation,d$records,drop=TRUE))
  data <- do.call(rbind,lapply(groups,function(r) {
    name <- if(r$engine[[1]]=="gravlax")"Gravlax classes" else if(op=="prepare")"SQL evidence cache" else
      if(endsWith(r$operation[[1]],"labels"))"SQL UMI labels"else"SQL evidence families"
    vals <- if(metric=="latency")r$elapsed_s*1000 else r$peak_rss_bytes/1024^2
    pass <- all(r$status=="PASS")
    data.frame(series=name,x=r$records[[1]]/1e6,y=if(pass)if(metric=="latency")median(vals)else max(vals)else NA_real_,
      lo=if(pass)min(vals)else NA_real_,hi=if(pass)max(vals)else NA_real_)
  }))
  chart(data,sprintf("site/assets/charts/aie-real-%s-t%d-%s.svg",op,threads,metric),
    paste(switch(op,prepare="Real PBMC preparation",`region-full`="Full chr1 query",`region-window`="3 Mb interval query"),paste0("· ",threads,"t")),
    if(metric=="latency")"CLI milliseconds · differing count/state policies"else"Maximum whole-CLI RSS (MiB)",
    "Genuine primary alignment records (millions)",
    "Three fresh processes per point on actual PBMC BAM prefixes, not replicated cells. Count meanings differ: SQL raw-UMI labels, overlap families, Gravlax classes. No equal-output speedup claim. Whiskers show the three-run range; short query timings are diagnostics.")
}

legacy <- read.delim("demos/ldzip/evidence/legacy/build.tsv")
for(bits in c(8,16)) for(metric in c("latency","rss")) {
  raw <- legacy[legacy$bits==bits,,drop=FALSE]
  groups <- split(raw,interaction(raw$format,raw$region,drop=TRUE))
  data <- do.call(rbind,lapply(groups,function(d) {
    vals <- if(metric=="latency")d$elapsed_s*1000 else d$max_rss_kb/1024
    data.frame(series=if(d$format[[1]]=="LDZip")"LDZip compress"else"DuckDB build",
      x=c(`1x`=250,`2x`=500,`4x`=1000)[d$region[[1]]],
      y=if(metric=="latency")median(vals)else max(vals),lo=min(vals),hi=max(vals))
  }))
  chart(data,sprintf("site/assets/charts/ld-build-%db-%s.svg",bits,metric),
    sprintf("%d-bit build · nested chr20 regions",bits),
    if(metric=="latency")"Milliseconds / build, three fresh processes"else"Maximum whole-process peak RSS (MiB)",
    "Nested region span (kb; not exact row scaling)",
    "Historical build receipts: default DuckDB threads and differing output representations. Three-process median latency/range and maximum RSS. LDZip compression excludes SQLite-index construction. The legacy harness did not enforce every declared resource budget; these are scoped measurements, not full STYLE qualification.")
}

native <- rbind(read.delim("demos/ldzip/evidence/native/ladder/summary.tsv"),
                read.delim("demos/ldzip/evidence/native/checkpoint/summary.tsv"))
for(bits in c(8,16)) for(threads in c(1,4)) for(metric in c("latency","rss")) {
  d <- native[native$bits==bits & native$threads==threads,,drop=FALSE]
  data <- data.frame(series=c(sql="SQL grid",tinycc="TinyCC SQL matrix",ldzip="LDZip R matrix")[d$engine],x=d$n,
    y=if(metric=="latency")d$median_process_mean_ms else d$max_peak_rss_bytes/1024^2,
    lo=if(metric=="latency")d$min_process_mean_ms else d$max_peak_rss_bytes/1024^2,
    hi=if(metric=="latency")d$max_process_mean_ms else d$max_peak_rss_bytes/1024^2)
  data$y[d$cell_status!="PASS"] <- NA_real_
  data$lo[d$cell_status!="PASS"] <- data$hi[d$cell_status!="PASS"] <- NA_real_
  # LDZip's R endpoint has one native reader, not a four-thread matrix implementation.
  if(threads==4) {
    ld <- native[native$bits==bits & native$threads==1 & native$engine=="ldzip",,drop=FALSE]
    data <- rbind(data,data.frame(series="LDZip R matrix",x=ld$n,
      y=if(metric=="latency")ld$median_process_mean_ms else ld$max_peak_rss_bytes/1024^2,
      lo=if(metric=="latency")ld$min_process_mean_ms else ld$max_peak_rss_bytes/1024^2,
      hi=if(metric=="latency")ld$max_process_mean_ms else ld$max_peak_rss_bytes/1024^2))
  }
  chart(data,sprintf("site/assets/charts/ld-native-%db-t%d-%s.svg",bits,threads,metric),
    sprintf("%d-bit matrices · %d SQL threads",bits,threads),if(metric=="latency")"Milliseconds / operation · lower is better"else"Whole-process peak RSS (MiB)",
    "Requested variants per matrix axis",
    "SQL and TinyCC retain SQL lists; LDZip returns an R matrix. These representations differ. Red crosses mark failed resource qualification; failed timings are not shown. Three fresh processes, at least five measured seconds each; whiskers are ranges of process-average latencies.")
}

peak <- jsonlite::fromJSON("demos/peakwhere/benchmarks/results.json",simplifyVector=FALSE)
for(metric in c("latency","rss")) {
  data <- list()
  for(w in c("W1","W2")) for(engine in c("wasm","native-1t","native-nt","chipseeker")) {
    if(engine=="wasm" && metric=="rss") next
    runs <- Filter(function(r)!r$warmup,peak[[w]]$runs)
    vals <- vapply(runs,function(r)if(metric=="latency")r$engines[[engine]]$seconds$total else r$engines[[engine]]$rss_kb/1024,0)
    data[[length(data)+1L]] <- data.frame(series=c(wasm="DuckDB-Wasm",`native-1t`="DuckDB 1t",`native-nt`="DuckDB multithread",chipseeker="ChIPseeker")[engine],
      x=match(w,c("W1","W2")),y=median(vals),lo=min(vals),hi=max(vals))
  }
  chart(do.call(rbind,data),paste0("site/assets/charts/peakwhere-",metric,".svg"),
    if(metric=="latency")"Peak annotation analysis time"else"Peak annotation memory",
    if(metric=="latency")"Seconds, excluding startup · lower is better"else"Whole-process peak RSS (MiB) · browser unmeasured",
    "1 = W1 chr19 · 2 = W2 full workload (not a row ladder)",
    "Five runs after a discarded warmup. ChIPseeker uses different category rules and does additional annotation; this is not an equal-output speedup. W1 independently validated; W2 oracle timed out. Whiskers show min/max.")
}
