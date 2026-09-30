
<!-- Render with `make performance`; timing receipts come from `Rscript bench/run.R`. -->

# Performance comparison

[Issue \#1](https://github.com/sounkou-bioinfo/duckpeakwhere/issues/1)
compares [duckpeakwhere](../README.md)’s SQL in duckdb-wasm and native
DuckDB with ChIPseeker `annotatePeak`. Sean Davis’s peakwhere is not
timed: its `src/pipeline.js` is a stub. The independent base-R oracle is
a correctness reference, not a timing competitor. These are local
measurements, not CI benchmarks.

## Headline

Seconds, **median \[min–max\] of five runs**, after one discarded
warm-up. Total means the two analysis phases, excluding engine startup;
native totals sum DuckDB’s per-statement wall timers. See process wall
times below for startup-inclusive native and R measurements. ChIPseeker
performs additional nearest-transcript annotation and has different
category rules, so this is not an equal-output speedup claim.

| Workload | wasm                     | native-1t             | native-nt             | chipseeker               |
|:---------|:-------------------------|:----------------------|:----------------------|:-------------------------|
| W1       | 0.728 \[0.720–0.765\]    | 0.401 \[0.390–0.405\] | 0.370 \[0.368–0.380\] | 2.776 \[2.645–3.009\]    |
| W2       | 13.623 \[13.568–13.704\] | 9.699 \[9.655–9.758\] | 7.395 \[7.385–7.444\] | 25.782 \[25.746–25.805\] |

W1 contains all 7,220 bundled mouse thymus chr19 peaks in five files,
against GENCODE M25 basic chr19 (mm10/GRCm38). W2 requests the full
versions of those same GENCODE and ENCODE files. A failed workload has
no timing entries.

## Reproduce

From the repository root, with the app’s vendor files staged, the DuckDB
CLI, `/usr/bin/time`, headless Chromium, and R packages ChIPseeker,
txdbmaker, GenomicFeatures, jsonlite, processx, BiocManager, knitr and
rmarkdown installed:

``` bash
node bench/stage.mjs W1
Rscript bench/run.R W1
Rscript bench/run.R W2
make performance
make readme
```

[`bench/manifest.json`](../bench/manifest.json) pins the signed native
DuckHTS archive and all six full-genome input URLs and SHA-256s.
`bench/run.R` calls the staging script before the workload;
`node bench/stage.mjs W2` also stages W2 directly. Staging verifies the
compressed bytes on every invocation and extracts to
`duckhts.duckdb_extension` (the basename determines the init symbol).
Downloads stay in ignored `bench/.cache/`.
[`results.json`](results.json) contains per-run receipts, including the
discarded warm-up, counts, source/input SHA-256s, versions, native
statement timings and `/usr/bin/time -v` output. Native reports DuckHTS
1.5.2 in `duckdb_extensions()`. That version field is blank in wasm,
whose release identity is instead established by checking the staged
artifact against `duckhts-manifest.json`’s pinned SHA-256 before every
run. Rendering reads these receipts; it does not rerun engines or
download data.

## Measurement contract

- One warm-up and five measured runs per workload and engine, in fixed
  order: wasm, native-1t, native-nt, ChIPseeker. Each native/R run is a
  fresh process; each wasm run is a fresh page (and browser). OS caches
  are not flushed. Engines run serially. Each engine has a 600-second
  wall limit, including warm-up.
- Browser timing uses `performance.now()` at phase boundaries in the
  actual `annotate()` call. Phase **partition** starts before annotation
  header reading and includes feature/category construction and the
  partition index. Phase **count** includes all five peak files,
  chromosome diagnostics, genome background, metadata queries and index
  destruction, exactly as in the app. Rendering and database/extension
  startup are excluded.
- The browser captures the SQL issued by `src/annotate.js`. Native
  replays that text, rather than maintaining a SQL copy. The three
  engines’ statement/phase SHA-256s must match for each repetition.
  Native uses the **same local HTTP URLs** while the browser’s server
  remains alive; thus path literals also match exactly. No remote
  requests occur during analysis. Native local-file performance is not
  measured. Whole-file DuckHTS reads use `scan_mode := 'sequential'`.
- Native **partition/count/total** sum CLI `.timer on` real seconds per
  statement (printed at millisecond precision; small statements can
  round to zero). CLI stdout is retained: it includes the
  deprecated-lambda warning from the app SQL. Only the non-empty
  priority/count result sets are parsed for the native gate.
  **process_wall** measures the entire `/usr/bin/time ... duckdb`
  invocation, including loading, transport, CLI JSON serialization, and
  shutdown. The native SQL thread setting is either 1 or the CLI
  default; it is recorded, not assumed.
- ChIPseeker **partition** is GFF3 → TxDb; **count** reads the five BED
  files, constructs one-base centres, calls `annotatePeak`, and
  tabulates categories. **total** sums those phases. Package loading is
  outside analysis total but inside **process_wall**, which covers the
  fresh Rscript invocation and receipt writing. Annotation feature
  caches are shared across the five files within one run only.
- Native and R peak RSS come from `/usr/bin/time -v`, over the whole
  process. Browser memory is **not measured**. The host is shared with
  unrelated processes, with no CPU affinity or exclusive reservation.
  This single-machine, fixed-order sample has no confidence intervals
  and does not isolate CPU kernels from I/O or startup.

## Correctness gates and measurements

No workload timing is published unless all of its SQL correctness gates
pass. Every run, including warm-up, is checked. W1 requires the six
counts for each file to equal `test/fixtures/thymus-expected.json`
exactly, with zero unmatched peaks; `test/oracle.R` must reproduce that
fixture byte for byte. W2 requires exact count and unmatched-peak
agreement among all three SQL engines, across all repetitions, and exact
count agreement with the independent oracle if it finishes within **120
seconds**. An oracle timeout is reported explicitly; an oracle error or
a count mismatch stops the workload. `test/oracle.R` accepts annotation,
peak-directory and output paths, using the same base-R algorithm as W1.
A failed workload writes a failure receipt and exits nonzero;
`make performance` can then render the failure without any partial
timings. ChIPseeker is not required to match SQL: input totals,
recognized category labels, and repeatability are checked, with dropped
peaks reported separately. Its disagreement is never used to relax the
SQL gate.

The brute-force oracle has a chromosome-scope limit: `category_of()`
assigns a chromosome absent from its interval list to intergenic, while
SQL excludes annotation-unmatched peaks. W2 includes 23 such peaks. This
is an additional reason not to claim independent W2 validation: a
completed oracle remains subject to exact comparison, with no exception
for those peaks. The oracle’s chromosome rule is not used as a
substitute for peakwhere’s tested exclusion rule.

### W1

Measured/attempted: 2026-09-23 17:44:52 UTC

Oracle: **passed**; limit 600 seconds.

Every SQL run exactly matches thymus-expected.json. Identical SQL hashes
across engines; ChIPseeker counts stable and input totals verified.

Input peaks: 7220.

| Engine     | Phase        | Seconds: median \[min–max\] |
|:-----------|:-------------|:----------------------------|
| wasm       | partition    | 0.611 \[0.607–0.643\]       |
| wasm       | count        | 0.117 \[0.113–0.121\]       |
| wasm       | total        | 0.728 \[0.720–0.765\]       |
| native-1t  | partition    | 0.355 \[0.353–0.364\]       |
| native-1t  | count        | 0.040 \[0.037–0.048\]       |
| native-1t  | total        | 0.401 \[0.390–0.405\]       |
| native-1t  | process_wall | 0.454 \[0.439–0.460\]       |
| native-nt  | partition    | 0.321 \[0.314–0.325\]       |
| native-nt  | count        | 0.054 \[0.049–0.057\]       |
| native-nt  | total        | 0.370 \[0.368–0.380\]       |
| native-nt  | process_wall | 0.431 \[0.422–0.437\]       |
| chipseeker | partition    | 1.275 \[1.226–1.367\]       |
| chipseeker | count        | 1.498 \[1.419–1.642\]       |
| chipseeker | total        | 2.776 \[2.645–3.009\]       |
| chipseeker | process_wall | 8.289 \[8.260–8.545\]       |

| Engine     | Peak RSS MiB: median \[min–max\] |
|:-----------|:---------------------------------|
| wasm       | not measured                     |
| native-1t  | 178.6 \[177.6–178.9\]            |
| native-nt  | 335.3 \[331.2–337.9\]            |
| chipseeker | 1198.4 \[1198.0–1199.3\]         |

### W2

Measured/attempted: 2026-09-23 17:43:21 UTC

Oracle: **timeout**; limit 120 seconds.

No independent counts were obtained.

``` text
Rscript test/oracle.R bench/.cache/W2/gencode.vM25.basic.annotation.gff3.gz bench/.cache/W2 /tmp/duckpeakwhere-bench-33ffe038b5696a/oracle.json
exit_status: -9
stdout: (empty)
stderr: (empty)
```

All SQL runs agree exactly; the independent oracle timed out. Identical
SQL hashes across engines; ChIPseeker counts stable and input totals
verified.

Input peaks: 221308.

SQL unmatched contigs: `chr4_GL456216_random`, `chrUn_GL456359`,
`chrUn_GL456370`, `chrUn_GL456393`, `chrUn_JH584304`,
`chrX_GL456233_random`.

| Engine     | Phase        | Seconds: median \[min–max\] |
|:-----------|:-------------|:----------------------------|
| wasm       | partition    | 12.809 \[12.759–12.897\]    |
| wasm       | count        | 0.808 \[0.784–0.843\]       |
| wasm       | total        | 13.623 \[13.568–13.704\]    |
| native-1t  | partition    | 9.235 \[9.176–9.278\]       |
| native-1t  | count        | 0.476 \[0.464–0.480\]       |
| native-1t  | total        | 9.699 \[9.655–9.758\]       |
| native-1t  | process_wall | 9.842 \[9.787–9.899\]       |
| native-nt  | partition    | 6.987 \[6.979–7.036\]       |
| native-nt  | count        | 0.408 \[0.399–0.416\]       |
| native-nt  | total        | 7.395 \[7.385–7.444\]       |
| native-nt  | process_wall | 7.598 \[7.584–7.638\]       |
| chipseeker | partition    | 16.297 \[16.229–16.349\]    |
| chipseeker | count        | 9.496 \[9.397–9.554\]       |
| chipseeker | total        | 25.782 \[25.746–25.805\]    |
| chipseeker | process_wall | 31.214 \[31.154–31.246\]    |

| Engine     | Peak RSS MiB: median \[min–max\] |
|:-----------|:---------------------------------|
| wasm       | not measured                     |
| native-1t  | 3297.3 \[3293.1–3298.0\]         |
| native-nt  | 4903.3 \[4825.6–4934.7\]         |
| chipseeker | 2142.7 \[2142.2–2143.0\]         |

## ChIPseeker agreement

Configuration: ChIPseeker 1.48.0; TxDb constructed from the **same
GFF3**; `level = 'transcript'`; `tssRegion = c(-1000, 1000)`;
`genomicAnnotationPriority = c('Promoter', '5UTR', '3UTR', 'Exon', 'Intron', 'Intergenic')`;
`ignoreDownstream = TRUE`. A BED interval `[s,e)` becomes a one-base
GRanges interval at `s + (e-s) %/% 2 + 1` (one-based). There is no
summit-based or whole-peak counting.

Relevant rule differences, checked in the installed ChIPseeker functions
`annotatePeak`, `getNearestFeatureIndicesAndDistances` and
`getGenomicAnnotation`:

- Both use transcript-level features here; **gene-level TSS is not the
  chosen setting**. SQL assigns promoter if *any* eligible transcript’s
  ±1 kb interval contains the centre. ChIPseeker assigns promoter from
  its selected nearest-feature distance. In 1.48.0,
  `ignoreDownstream=TRUE` selects the `follow()` candidate on unstranded
  genomic coordinates (with TSS-overlap handling), not the minimum
  absolute distance of the two flanking TSS candidates. This can change
  promoters.
- `ignoreDownstream` does **not** disable downstream output labels.
  ChIPseeker’s category function still labels remaining intergenic
  centres within its default 3 kb downstream distance. Those labels are
  explicitly folded into **intergenic**; the number folded is shown
  below. SQL has no downstream category.
- SQL uses explicit GFF3 five/three-prime UTR features. TxDb represents
  CDS/exon structure and ChIPseeker obtains UTRs from
  `fiveUTRsByTranscript` and `threeUTRsByTranscript`; the annotation
  representations need not coincide.
- SQL treats transcript spans as intronic after higher-priority
  intervals are removed. ChIPseeker uses exon-gap introns from TxDb.
  TxDb transcript recognition and validation can differ from SQL’s rule
  (a transcript is a parent of an exon). Construction warnings and
  transcript counts are retained in the receipts.
- Exon and intron transcript IDs/numbers and promoter distance labels
  are collapsed to their six category names, not compared as strings.
  Neither engine filters protein-coding transcripts or requires peak
  strand. SQL normalizes contig names and reports unmatched chromosomes;
  ChIPseeker uses TxDb sequence names and may omit centres lacking
  usable features. Such omissions are reported, not imputed.

An untimed W2 diagnostic replay with `options(warn = 1)` reproduced the
recorded ChIPseeker counts and dropped totals exactly. Its 20 annotation
warnings came from `.merge_two_Seqinfo_objects`: the peak files contain
random/unplaced contigs absent from TxDb, while TxDb contains chrM (and,
for some files, chrY) absent from the peaks. The SQL-unmatched contigs
are listed above. TxDb construction also warns that stop-codon phase
values are ignored and genome-version metadata is unavailable; the
GRCm38 identity here comes from the pinned source provenance, not TxDb
metadata.

Differences below are **ChIPseeker − SQL**. These are marginal category
counts, not per-peak concordance: equal totals do not prove the same
peaks received a category. No individual discrepancy is claimed to have
been causally decomposed.

### W1

| Mark     | Category   |  SQL | ChIPseeker | ChIPseeker − SQL |
|:---------|:-----------|-----:|-----------:|-----------------:|
| CTCF     | promoter   |  360 |        215 |             -145 |
| CTCF     | utr5       |    0 |         27 |               27 |
| CTCF     | utr3       |   15 |         18 |                3 |
| CTCF     | exon       |   28 |         49 |               21 |
| CTCF     | intron     |  192 |        225 |               33 |
| CTCF     | intergenic |  111 |        172 |               61 |
| DNase    | promoter   |  893 |        532 |             -361 |
| DNase    | utr5       |    1 |         41 |               40 |
| DNase    | utr3       |   47 |         52 |                5 |
| DNase    | exon       |   60 |         99 |               39 |
| DNase    | intron     |  732 |        853 |              121 |
| DNase    | intergenic |  462 |        618 |              156 |
| H3K27me3 | promoter   |  233 |        127 |             -106 |
| H3K27me3 | utr5       |    1 |         15 |               14 |
| H3K27me3 | utr3       |   13 |         13 |                0 |
| H3K27me3 | exon       |   29 |         50 |               21 |
| H3K27me3 | intron     |  148 |        189 |               41 |
| H3K27me3 | intergenic |  181 |        211 |               30 |
| H3K36me3 | promoter   |   96 |         46 |              -50 |
| H3K36me3 | utr5       |    5 |          7 |                2 |
| H3K36me3 | utr3       |  226 |        230 |                4 |
| H3K36me3 | exon       |  440 |        452 |               12 |
| H3K36me3 | intron     | 2007 |       2039 |               32 |
| H3K36me3 | intergenic |   81 |         81 |                0 |
| H3K4me3  | promoter   |  594 |        346 |             -248 |
| H3K4me3  | utr5       |    1 |         42 |               41 |
| H3K4me3  | utr3       |    8 |         10 |                2 |
| H3K4me3  | exon       |   30 |         78 |               48 |
| H3K4me3  | intron     |  148 |        251 |              103 |
| H3K4me3  | intergenic |   78 |        132 |               54 |
| All      | promoter   | 2176 |       1266 |             -910 |
| All      | utr5       |    8 |        132 |              124 |
| All      | utr3       |  309 |        323 |               14 |
| All      | exon       |  587 |        728 |              141 |
| All      | intron     | 3227 |       3557 |              330 |
| All      | intergenic |  913 |       1214 |              301 |

| Mark     | Input | SQL unmatched | ChIPseeker dropped | Downstream folded to intergenic |
|:---------|------:|--------------:|-------------------:|--------------------------------:|
| CTCF     |   706 |             0 |                  0 |                               3 |
| DNase    |  2195 |             0 |                  0 |                               6 |
| H3K27me3 |   605 |             0 |                  0 |                               1 |
| H3K36me3 |  2855 |             0 |                  0 |                              11 |
| H3K4me3  |   859 |             0 |                  0 |                               0 |

SQL transcripts: 2303; TxDb transcripts: 2303.

### W2

| Mark     | Category   |    SQL | ChIPseeker | ChIPseeker − SQL |
|:---------|:-----------|-------:|-----------:|-----------------:|
| CTCF     | promoter   |   9191 |       5695 |            -3496 |
| CTCF     | utr5       |     21 |        681 |              660 |
| CTCF     | utr3       |    384 |        407 |               23 |
| CTCF     | exon       |    825 |       1395 |              570 |
| CTCF     | intron     |   5193 |       6069 |              876 |
| CTCF     | intergenic |   4591 |       5958 |             1367 |
| DNase    | promoter   |  25018 |      14785 |           -10233 |
| DNase    | utr5       |     80 |       1441 |             1361 |
| DNase    | utr3       |   1024 |       1077 |               53 |
| DNase    | exon       |   1965 |       3239 |             1274 |
| DNase    | intron     |  21844 |      25378 |             3534 |
| DNase    | intergenic |  17998 |      22009 |             4011 |
| H3K27me3 | promoter   |   6976 |       3853 |            -3123 |
| H3K27me3 | utr5       |     39 |        414 |              375 |
| H3K27me3 | utr3       |    378 |        407 |               29 |
| H3K27me3 | exon       |    960 |       1492 |              532 |
| H3K27me3 | intron     |   4212 |       5536 |             1324 |
| H3K27me3 | intergenic |   4020 |       4883 |              863 |
| H3K36me3 | promoter   |   3067 |       1600 |            -1467 |
| H3K36me3 | utr5       |     96 |        127 |               31 |
| H3K36me3 | utr3       |   6533 |       6652 |              119 |
| H3K36me3 | exon       |  13986 |      14362 |              376 |
| H3K36me3 | intron     |  65384 |      66255 |              871 |
| H3K36me3 | intergenic |   2407 |       2477 |               70 |
| H3K4me3  | promoter   |  17291 |       9922 |            -7369 |
| H3K4me3  | utr5       |     39 |       1244 |             1205 |
| H3K4me3  | utr3       |    193 |        228 |               35 |
| H3K4me3  | exon       |    807 |       2211 |             1404 |
| H3K4me3  | intron     |   3947 |       7217 |             3270 |
| H3K4me3  | intergenic |   2816 |       4271 |             1455 |
| All      | promoter   |  61543 |      35855 |           -25688 |
| All      | utr5       |    275 |       3907 |             3632 |
| All      | utr3       |   8512 |       8771 |              259 |
| All      | exon       |  18543 |      22699 |             4156 |
| All      | intron     | 100580 |     110455 |             9875 |
| All      | intergenic |  31832 |      39598 |             7766 |

| Mark     | Input | SQL unmatched | ChIPseeker dropped | Downstream folded to intergenic |
|:---------|------:|--------------:|-------------------:|--------------------------------:|
| CTCF     | 20220 |            15 |                 15 |                              62 |
| DNase    | 67929 |             0 |                  0 |                             177 |
| H3K27me3 | 16586 |             1 |                  1 |                              45 |
| H3K36me3 | 91474 |             1 |                  1 |                             403 |
| H3K4me3  | 25099 |             6 |                  6 |                              42 |

SQL transcripts: 81540; TxDb transcripts: 81540.

## Environment and provenance

Source hashes in the receipts identify the measured working-tree files;
the Git revision alone is the base commit, not a claim that uncommitted
benchmark code was already part of that commit. Input hashes identify
the exact compressed files.

### W1

Measured: 2026-09-23 17:44:52 UTC

| Component           | Version                      |
|:--------------------|:-----------------------------|
| Node                | v24.14.1                     |
| duckdb-wasm package | 1.33.1-dev57.0               |
| wasm DuckDB         | v1.5.4                       |
| Chromium            | 148.0.7778.96                |
| wasm platform       | wasm_eh                      |
| native DuckDB       | v1.5.1                       |
| DuckHTS             | 1.5.2                        |
| R                   | R version 4.6.0 (2026-04-24) |
| Bioconductor        | 3.23                         |
| ChIPseeker          | 1.48.0                       |
| txdbmaker           | 1.8.0                        |
| GenomicFeatures     | 1.64.0                       |
| GenomicRanges       | 1.64.0                       |
| IRanges             | 2.46.0                       |
| rtracklayer         | 1.72.0                       |

Threads: wasm 1; native-1t 1; native-nt 20. Signed DuckHTS loaded with
`allow_unsigned_extensions=false` in all SQL engines.

``` text
CPU(s):                               20
Model name:                           13th Gen Intel(R) Core(TM) i5-13500
Thread(s) per core:                   2
Core(s) per socket:                   14
Socket(s):                            1
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.3 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=noble
LOGO=ubuntu-logo
Linux Ubuntu-2404-noble-amd64-base 6.8.0-78-generic #78-Ubuntu SMP PREEMPT_DYNAMIC Tue Aug 12 11:34:18 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
```

| File                                                     | SHA256                                                           |
|:---------------------------------------------------------|:-----------------------------------------------------------------|
| examples/gencode.vM25.basic.chr19.gff3.gz                | 5b6437177b7cbba4d076917819150bdeb113f54b39b1e2e33cfde5a8719243c8 |
| examples/thymus_CTCF_ENCFF714WDP.chr19.narrowPeak.gz     | 11fca62a167216eeae71acbddcc71467d8427fd393f8f7b4d438d08e3666f27d |
| examples/thymus_DNase_ENCFF979ULB.chr19.narrowPeak.gz    | 9afc1062b96cfa26dd65c32774fcc32616f66742ca44e9674b842209efebb9bc |
| examples/thymus_H3K27me3_ENCFF478UYW.chr19.narrowPeak.gz | 720ecc922fa8e6ef19bc32a36eefc2a5f144a4c107182bdd0fd191316a4fbc76 |
| examples/thymus_H3K36me3_ENCFF853BYO.chr19.narrowPeak.gz | da399745a2af18d1ada09e4f547530f60a90545d241c9c94734dc6e091f12740 |
| examples/thymus_H3K4me3_ENCFF674JZY.chr19.narrowPeak.gz  | 8b1a40a27f8690de5d64ed9865c75e4bfdeb3ceb3f864e41d36379b1251f04f9 |

### W2

Measured: 2026-09-23 17:43:21 UTC

| Component           | Version                      |
|:--------------------|:-----------------------------|
| Node                | v24.14.1                     |
| duckdb-wasm package | 1.33.1-dev57.0               |
| wasm DuckDB         | v1.5.4                       |
| Chromium            | 148.0.7778.96                |
| wasm platform       | wasm_eh                      |
| native DuckDB       | v1.5.1                       |
| DuckHTS             | 1.5.2                        |
| R                   | R version 4.6.0 (2026-04-24) |
| Bioconductor        | 3.23                         |
| ChIPseeker          | 1.48.0                       |
| txdbmaker           | 1.8.0                        |
| GenomicFeatures     | 1.64.0                       |
| GenomicRanges       | 1.64.0                       |
| IRanges             | 2.46.0                       |
| rtracklayer         | 1.72.0                       |

Threads: wasm 1; native-1t 1; native-nt 20. Signed DuckHTS loaded with
`allow_unsigned_extensions=false` in all SQL engines.

``` text
CPU(s):                               20
Model name:                           13th Gen Intel(R) Core(TM) i5-13500
Thread(s) per core:                   2
Core(s) per socket:                   14
Socket(s):                            1
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.3 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=noble
LOGO=ubuntu-logo
Linux Ubuntu-2404-noble-amd64-base 6.8.0-78-generic #78-Ubuntu SMP PREEMPT_DYNAMIC Tue Aug 12 11:34:18 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
```

| File                                                      | SHA256                                                           |
|:----------------------------------------------------------|:-----------------------------------------------------------------|
| bench/.cache/W2/gencode.vM25.basic.annotation.gff3.gz     | e8ed48bef6a44fdf0db7c10a551d4398aa341318d00fbd9efd69530593106846 |
| bench/.cache/W2/thymus_CTCF_ENCFF714WDP.narrowPeak.gz     | 15afa43aab7022c24a5f4324ca0b71203daf3121a9316f9049e5c58c6eab3572 |
| bench/.cache/W2/thymus_DNase_ENCFF979ULB.narrowPeak.gz    | 2fe1a60dc6412b93e0880601e5822746b7114702e1709423dcdb49a3a3656086 |
| bench/.cache/W2/thymus_H3K27me3_ENCFF478UYW.narrowPeak.gz | 9faf7f19d7dd80325fb22074b3f0c5f2eeb45a54e389df7e924540fea61b25b6 |
| bench/.cache/W2/thymus_H3K36me3_ENCFF853BYO.narrowPeak.gz | 014da868e773ac7e0c5f7392ba00592e497eb79acd4cc6254775577b02ffcf4c |
| bench/.cache/W2/thymus_H3K4me3_ENCFF674JZY.narrowPeak.gz  | ab6da876a876ade8c8467e8a84850d36b42af0df68a0606f077c547f8da5b93a |
