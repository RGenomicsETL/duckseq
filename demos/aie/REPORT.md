Gravlax AIE in DuckDB SQL
================

# Gravlax AIE in DuckDB SQL

DuckHTS reads the BAM and GTF inputs; SQL stores alignment identity,
CIGAR operations, molecule membership and placements in Parquet. Region,
junction, jset, annotation replay and signed annotation deltas match
pinned [Gravlax AIE
0.2.3](https://github.com/COMBINE-lab/Gravlax/tree/75b8d6c01064ba92af295543d50230429774e170)
on the checked-in two-sample fixture. This is fixture parity, not
exhaustive Gravlax compatibility.

## Gravlax comparison

These measurements use **1,024 / 2,048 / 4,096 distinct synthetic
cells**. Every cell has the recorded 28-alignment fixture topology, with
unique read names and cell barcodes. The archived template/source
snapshot defines this diagnostic; the compatibility fixture is tested
separately. The record counts scale exactly 1×/2×/4×; the reference
remains a 120-base chr1. Both engines receive the same sorted BAM. Every
timed region and junction output is checked as a complete cell/count
relation against Gravlax.

<figure>
<img src="../../site/assets/charts/aie-region-latency.svg"
alt="Region query, including CLI startup, reading persisted input, and writing every cell count. Whiskers show the three batch-average ranges." />
<figcaption aria-hidden="true">Region query, including CLI startup,
reading persisted input, and writing every cell count. Whiskers show the
three batch-average ranges.</figcaption>
</figure>

<figure>
<img src="../../site/assets/charts/aie-junction-latency.svg"
alt="Junction query, including CLI startup and output writing. One- and four-thread settings are explicit for both engines." />
<figcaption aria-hidden="true">Junction query, including CLI startup and
output writing. One- and four-thread settings are explicit for both
engines.</figcaption>
</figure>

<figure>
<img src="../../site/assets/charts/aie-region-rss.svg"
alt="Maximum region-query CLI peak RSS across each three-batch cell." />
<figcaption aria-hidden="true">Maximum region-query CLI peak RSS across
each three-batch cell.</figcaption>
</figure>

<figure>
<img src="../../site/assets/charts/aie-junction-rss.svg"
alt="Maximum junction-query CLI peak RSS across each three-batch cell." />
<figcaption aria-hidden="true">Maximum junction-query CLI peak RSS
across each three-batch cell.</figcaption>
</figure>

These are repeated **fresh-CLI diagnostics**, not resident-engine
timings. Three independent batches per point each accumulate at least
five measured seconds; every invocation starts a new process. Latency is
the median of three batch means, not the median of individual
invocations. Whiskers are the range of batch means, not confidence
intervals. RSS covers the entire CLI process.

The synthetic reference and short individual queries do **not**
establish DuckHTS STYLE operating-scale compliance or
public-transcriptome throughput. Annotation replay and jset performance
are unmeasured.

## Preparation: different representations

Gravlax writes its AIE archive. DuckDB writes the demo’s Parquet
relations, including read metadata, explicit geometry and placements.
Both preparations start from the same BAM, but the retained
representations differ; the query checks establish cell/count parity,
not storage-format equivalence.

<figure>
<img src="../../site/assets/charts/aie-prepare-latency.svg"
alt="Preparation wall time for the same BAM, with different retained representations." />
<figcaption aria-hidden="true">Preparation wall time for the same BAM,
with different retained representations.</figcaption>
</figure>

<figure>
<img src="../../site/assets/charts/aie-prepare-rss.svg"
alt="Preparation maximum whole-CLI peak RSS. The explicit thread settings apply to DuckDB and Gravlax’s Rayon pool." />
<figcaption aria-hidden="true">Preparation maximum whole-CLI peak RSS.
The explicit thread settings apply to DuckDB and Gravlax’s Rayon
pool.</figcaption>
</figure>

## Exact measurements and budgets

[Raw batch measurements](evidence/benchmark/raw.tsv), compressed
per-invocation receipts, source/input/runtime hashes and the manifest
are in [evidence/benchmark](evidence/benchmark). Failed invocations are
retained and end the batch; there is no retry. The preliminary,
uncontrolled-thread single-CLI run is not the source of these charts.

The [protocol](BENCHMARK_PROTOCOL.md) declares budgets before the
controlled run: 120 seconds and 2 GiB peak RSS per CLI, 2 GiB prepared
output per run, 64 MiB per stdout/stderr receipt. DuckDB has a 1 GiB
buffer limit and 512 MiB spill limit. DuckDB threads and
`RAYON_NUM_THREADS` are one/four; BLAS/OpenMP threads are one. All 108
controlled batches pass the recorded budgets and count-output checks.

| Engine  | Operation | Cells | Threads | CLI milliseconds: median \[min, max\] | Max RSS MiB | Prepared MiB |
|:--------|:----------|------:|--------:|:--------------------------------------|------------:|-------------:|
| gravlax | junction  |  1024 |       1 | 6.28 \[6.24, 6.72\]                   |        14.1 |           NA |
| sql     | junction  |  1024 |       1 | 30.68 \[30.51, 30.90\]                |        38.5 |           NA |
| gravlax | prepare   |  1024 |       1 | 365.64 \[364.50, 365.79\]             |        95.2 |        0.008 |
| sql     | prepare   |  1024 |       1 | 505.10 \[502.60, 505.40\]             |       160.5 |        1.256 |
| gravlax | region    |  1024 |       1 | 7.17 \[7.08, 7.22\]                   |        14.1 |           NA |
| sql     | region    |  1024 |       1 | 26.20 \[26.04, 27.90\]                |        37.8 |           NA |
| gravlax | junction  |  2048 |       1 | 8.23 \[8.20, 8.38\]                   |        15.9 |           NA |
| sql     | junction  |  2048 |       1 | 40.56 \[40.49, 42.45\]                |        42.1 |           NA |
| gravlax | prepare   |  2048 |       1 | 375.29 \[374.36, 376.79\]             |        98.6 |        0.013 |
| sql     | prepare   |  2048 |       1 | 931.00 \[925.17, 955.50\]             |       231.6 |        2.536 |
| gravlax | region    |  2048 |       1 | 10.05 \[10.00, 11.22\]                |        16.1 |           NA |
| sql     | region    |  2048 |       1 | 36.29 \[35.77, 36.32\]                |        44.6 |           NA |
| gravlax | junction  |  4096 |       1 | 11.86 \[11.75, 15.07\]                |        19.8 |           NA |
| sql     | junction  |  4096 |       1 | 61.50 \[61.41, 78.83\]                |        50.5 |           NA |
| gravlax | prepare   |  4096 |       1 | 451.33 \[449.58, 509.10\]             |       105.4 |        0.025 |
| sql     | prepare   |  4096 |       1 | 2193.67 \[1865.67, 2946.00\]          |       381.4 |        5.147 |
| gravlax | region    |  4096 |       1 | 15.95 \[15.50, 19.41\]                |        20.3 |           NA |
| sql     | region    |  4096 |       1 | 54.68 \[53.28, 77.82\]                |        53.1 |           NA |
| gravlax | junction  |  1024 |       4 | 6.42 \[6.42, 7.23\]                   |        14.1 |           NA |
| sql     | junction  |  1024 |       4 | 29.83 \[29.51, 36.06\]                |        45.1 |           NA |
| gravlax | prepare   |  1024 |       4 | 146.74 \[146.26, 147.24\]             |       336.3 |        0.008 |
| sql     | prepare   |  1024 |       4 | 406.00 \[404.62, 412.38\]             |       224.2 |        1.256 |
| gravlax | region    |  1024 |       4 | 7.33 \[7.31, 7.35\]                   |        14.1 |           NA |
| sql     | region    |  1024 |       4 | 25.25 \[24.80, 28.94\]                |        44.5 |           NA |
| gravlax | junction  |  2048 |       4 | 8.98 \[8.95, 9.49\]                   |        15.9 |           NA |
| sql     | junction  |  2048 |       4 | 42.65 \[41.70, 43.19\]                |        54.1 |           NA |
| gravlax | prepare   |  2048 |       4 | 158.25 \[157.75, 158.87\]             |       339.0 |        0.013 |
| sql     | prepare   |  2048 |       4 | 732.57 \[727.71, 733.14\]             |       333.9 |        2.536 |
| gravlax | region    |  2048 |       4 | 12.12 \[11.98, 12.15\]                |        16.1 |           NA |
| sql     | region    |  2048 |       4 | 35.98 \[35.72, 36.69\]                |        52.5 |           NA |
| gravlax | junction  |  4096 |       4 | 12.90 \[12.74, 13.33\]                |        19.8 |           NA |
| sql     | junction  |  4096 |       4 | 51.62 \[50.94, 51.93\]                |        67.2 |           NA |
| gravlax | prepare   |  4096 |       4 | 196.19 \[195.54, 198.08\]             |       346.4 |        0.025 |
| sql     | prepare   |  4096 |       4 | 1396.25 \[1395.00, 1402.25\]          |       580.2 |        5.147 |
| gravlax | region    |  4096 |       4 | 19.03 \[18.64, 19.16\]                |        20.3 |           NA |
| sql     | region    |  4096 |       4 | 46.76 \[46.36, 47.24\]                |        67.7 |           NA |

## Real-input shared-surface admission: failed

A [public PBMC compatibility pilot](evidence/real-pilot/README.md)
contains 109,271 real mapped NH=1 records from GRCh38 `1:1-3000000`.
Region counts differ in **653 of 4,615 cells**: Gravlax totals 42,974,
current SQL 41,901. This does not admit a real-input equal-output speed
comparison.

The source includes 2,613 raw/corrected barcode disagreements and 1,124
raw/corrected UMI disagreements. Gravlax ingestion consumes raw CR/UR;
SQL uses CB/UB. The fixture makes those tags equal. These observations
identify a compatibility gap without attributing every count discrepancy
to one cause. The pilot was derived by indexed access, not a full-cohort
run. Selecting supplied CB/raw UR reduces disagreement to one cell (28
versus 29). The independently specified product policy and real
1M/2M/4M-record cost comparison are in the [product
report](PRODUCT_REPORT.md); those counts are not silently substituted
for this compatibility surface.

## Compatibility rules and discriminating tests

- **CIGAR reference cursor:** M, D, N, = and X advance it. Only N
  contributes a splice junction. The fixture checks both later junctions
  of a multi-intron read, including `5M5N5M10N5M`.
- **Alignment identity:** a per-sample alignment ID distinguishes
  placements sharing the same read name and flag. The fixture includes
  three placements of one read, including two secondary records with
  flag 256.
- **Deletion geometry:** D extends an alignment block; treating it as a
  splice rejects a valid geneD assignment.
- **UMI rank:** candidate parents precede the UMI by descending
  abundance, then ascending packed-value/lexical order. An
  equal-abundance, smaller UMI may be a parent. The 3/1/2 chain and
  equal-abundance branch/square fixtures distinguish abundance,
  exact-only matching and tie order.
- **Alternative placements:** annotation replay considers secondary
  placements before singleton-gene assignment. Cross-gene alternatives
  make a molecule ambiguous; same-gene alternatives remain assignable.

The mutation suite requires explicit count disagreements with Gravlax.
Setup, SQL parser/binder/runtime failures and timeouts are harness
failures, not killed mutants. Restored SQL must pass after every mutant.
See the [fixture rules and upstream source
references](fixture/README.md) and [schema](SCHEMA.md).

## Contrast

| Question                                              | DuckDB SQL                                                 | Gravlax                                                                               |
|-------------------------------------------------------|------------------------------------------------------------|---------------------------------------------------------------------------------------|
| Region/junction cell counts on these synthetic inputs | Exact admitted output; inspect latency/RSS charts          | Exact reference output; inspect latency/RSS charts                                    |
| Retained data                                         | Composable Parquet metadata, CIGAR and placement relations | Dedicated compact archive and purpose-built queries                                   |
| Annotation replay and signed deltas                   | Exact parity on both fixture annotation versions           | Reference implementation; broader behavior is not established by this fixture         |
| Broader shared-semantic input modes                   | Unverified beyond the fixture and recorded pilot           | Original tool; this compatibility surface does not replace its general input pipeline |

## Reproduce

``` bash
cd demos/aie
eval "$(./setup.sh)"
./test.sh
./mutation_test.sh
AIE_BENCH_THREADS=1 AIE_BENCH_OUT=work/benchmark-controlled-t1 Rscript --vanilla benchmark.R
AIE_BENCH_THREADS=4 AIE_BENCH_OUT=work/benchmark-controlled-t4 Rscript --vanilla benchmark.R
```

Use new output directories: the harness refuses to overwrite receipts.
Render this report from the committed evidence with
`Rscript -e 'rmarkdown::render("REPORT.Rmd", quiet=TRUE)'`. Benchmark
charts are regenerated from the repository root with
`Rscript scripts/plot-benchmarks.R`. Rendering does not download inputs
or run benchmark engines.
