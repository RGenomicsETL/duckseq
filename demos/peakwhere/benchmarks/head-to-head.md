
<!-- Render with make head-to-head; the drivers write the JSON receipts. -->

# Head-to-head: duckpeakwhere vs upstream peakwhere

W2 on the same 13th Gen Intel Core i5-13500 (20 logical CPUs), headless
Chromium 148.0.7778.96. One warm-up plus five measured app runs, each in
a fresh browser. Timing jobs ran sequentially, without another test or
benchmark job launched alongside them. Resident system and agent
services remained; this was not an exclusive host.

- **Upstream:**
  [seandavi/peakwhere](https://github.com/seandavi/peakwhere) at
  `f40a673842815b9eef08c4d32243b29dac3e0646`, using its committed
  application and real file inputs. The upstream receipt is the
  committed 2026-09-23 measurement, not a new run.
- **duckpeakwhere measured commit:**
  e27ecb13b9d06084013237d397661400ddbb0856, signed DuckHTS 1.5.2,
  duckdb-wasm 1.5.4 (`wasm_eh`, one thread), W2 files over same-origin
  HTTP.
- **Inputs:** full GENCODE vM25 basic and full ENCODE thymus narrowPeak
  files ENCFF714WDP, ENCFF979ULB, ENCFF478UYW, ENCFF853BYO, ENCFF674JZY.
  Compressed hashes were verified against `bench/manifest.json`. There
  are 221,308 peaks.
- **Settings:** promoter −1000/+1000, centres, all transcripts. The
  first redraw switches to bp; the second changes promoter upstream to
  2000, retaining bp mode.
- **Driver:**
  `node bench/head-to-head-ours.mjs 6 benchmarks/head-to-head-ours.json`.
  It submits the real app form, waits for rendered results, and uses the
  same session on redraws. Startup is navigation to the ready app and is
  outside first-analysis time.

## Seconds, median \[min–max\] of five runs

| step                                |              upstream |         duckpeakwhere |
|:------------------------------------|----------------------:|----------------------:|
| App startup                         |                     — | 0.886 \[0.880–0.892\] |
| First analysis (Run → results)      | 4.351 \[4.341–4.381\] | 6.061 \[6.003–6.141\] |
| Redraw: centres → base pairs        | 0.525 \[0.513–0.537\] | 0.294 \[0.293–0.304\] |
| Redraw: promoter upstream 2000 (bp) | 0.494 \[0.479–0.506\] | 1.814 \[1.794–1.841\] |

Upstream includes a 300 ms redraw debounce. duckpeakwhere measures
submission through rendering, with no debounce. Neither driver observed
off-origin requests. The bp redraw is under one second; the promoter
redraw is **not**: it rebuilds categories and the cgranges partition.
The first analysis remains slower than upstream’s 4.35 s. The full
feature read remains a [DuckHTS
\#249](https://github.com/RGenomicsETL/duckhts/issues/249) work item;
there is no application-side parser or projection workaround.

| step            |                before |                 after |
|:----------------|----------------------:|----------------------:|
| First analysis  | 6.588 \[6.523–6.692\] | 6.061 \[6.003–6.141\] |
| Mode redraw     | 7.185 \[7.109–7.317\] | 0.294 \[0.293–0.304\] |
| Promoter redraw | 6.258 \[6.213–6.532\] | 1.814 \[1.794–1.841\] |

The before receipt is preserved at
`71c4674:benchmarks/head-to-head-ours.json` (the report identifies its
source as `5fa746b`). Its driver called uncached `annotate` without
rendering, and reset to centre mode for the promoter measurement. The
after driver includes rendering and keeps bp mode, matching upstream.
The promoter rows therefore compare workflows, not identical settings or
identical timing boundaries.

## Exact agreement

| file     | identical_categories |  of |
|:---------|---------------------:|----:|
| CTCF     |                    6 |   6 |
| DNase    |                    6 |   6 |
| H3K27me3 |                    6 |   6 |
| H3K36me3 |                    6 |   6 |
| H3K4me3  |                    6 |   6 |

All 30 centre counts match both immutable pre-port receipts on **every**
timed run and warm-up, including native replay. This is independent
upstream peakwhere agreement; it is not a claim that the separate W2 R
oracle finished. That oracle’s timeout remains recorded in
[performance.md](performance.md). PeakPeek expectations are still its
own SPEC and tests at `a05b661`
([a05b6615b1c51c41781b6a1f2081868fbc2b711e](https://github.com/seandavi/peakpeek/tree/a05b6615b1c51c41781b6a1f2081868fbc2b711e)),
not outputs from this port. The expected file’s values were re-checked
against that commit: the fixture expectations against
`examples/fixture.js` and the five thymus rows against `SPEC.md` §2. (An
earlier revision of this report cited a PeakPeek commit `4f91069` that
does not exist; it was a recording error, corrected here.)

## SQL decisions and measured effects

- **Segment labelling and centre counting keep cgranges.** The supplied
  native-1t W2 comparison found segment labelling at 0.84 s versus 1.64
  s for islands + ASOF, 1.51 s for islands + genome-coordinate IEJoin,
  and 1.68 s for IEJoin without islands. Centre probes took 0.079 s
  versus ASOF’s 0.116 s. These operator experiments were not repeated.
  CTE range-join plans with poor estimates are not adopted.
- **Parent decoding:** only values containing `%` call `url_decode`; the
  supplied exact-equality measurement was 0.69 → 0.62 s native. Plain
  and encoded multi-parent links have a regression fixture.
- **File reads and caching:** one peak scan supplies validation, both
  views, contig reports and past-end warnings. The supplied profile
  attributed 0.32 of 0.70 s of count time to redundant reads. Annotation
  tables and the partition survive redraws; only dependent tables are
  rebuilt. File selection changes scan only added/replaced peak files.
  SQL-trace tests check the invalidation boundaries.
- **Bp reduction:** one materialized overlap list per matched peak feeds
  five genic sums; intergenic is total width minus those sums. Cache the
  annotation contig set rather than scanning all features per file. A
  bounded W2 browser probe measured bp 1.255 → 0.286 s and promoter-bp
  2.744 → 1.793 s for these two changes together; all category counts at
  both bp settings exactly matched the pre-change SQL. This is a
  regression comparison, not an independent oracle. Independent hand
  fixtures check bp semantics. EXPLAIN JSON shows list
  reductions/`UNGROUPED_AGGREGATE`, a contig-membership `HASH_JOIN`, and
  no lateral `INOUT_FUNCTION`/UNNEST.
- **Peek histogram:** the bin grid and accepted rows are materialized
  temp tables. EXPLAIN on the 30-bin/17-row fixture selects
  `BLOCKWISE_NL_JOIN` for the inclusive last-bin predicate. No speedup
  is claimed for this materialization. There is no new interval range
  join in Where.

## Threading

`node bench/threading.mjs 3 benchmarks/threading.json` replays identical
captured app SQL over the same local HTTP URLs in signed native DuckDB
v1.5.1. One warm-up and three measured runs per setting; setting order
alternates. These are first-analysis SQL times, not app redraws or
native local-file I/O.

| engine    | threads |               seconds |                     rss_MiB |
|:----------|--------:|----------------------:|----------------------------:|
| native-1t |       1 | 4.077 \[4.058–4.102\] | 602.344 \[602.258–602.551\] |
| native-nt |      20 | 3.834 \[3.801–3.937\] | 783.148 \[769.211–791.836\] |

The deployed browser probe reports crossOriginIsolated = **FALSE**,
SharedArrayBuffer = **FALSE**, platform **wasm_eh**, and 1 thread.
Signed extensions remain enforced and there are no off-origin requests.
**Browser threading is not usable in this deployment as served.** GitHub
Pages cannot set COOP/COEP response headers. A same-origin
`coi-serviceworker` could establish isolation, but worker
registration/reload behavior and signed `wasm_threads` execution would
need a separate browser benchmark. No service worker or threaded bundle
is adopted; native thread scaling does not establish a browser speedup.
Threaded-browser throughput is unverified.
