LDZip matrices in DuckDB SQL
================

# LDZip matrices in DuckDB SQL

## Question and scope

LDZip (MIT, commit `f8e363af03b2101b04e56b142595a16a060856b6`) stores
sparse quantized LD values in `.x.*.bin`, `.i.bin`, `.p.bin`, and index
files, with a separate SQLite variant index. This demo tests whether the
same tutorial-derived matrix and allele-aware variant keys can be stored
in sorted Parquet and queried through DuckDB SQL. The comparison is
limited to the chr20 tutorial regions and operations below; it does not
claim that this conversion replaces LDZip’s general-purpose pipeline or
all of its metadata.

The input is the LDZip 1000 Genomes chr20 tutorial VCF, checksummed in
`checksums.txt`, and the tutorial’s EUR sample panel. The checked
regions are nested spans from 20,000,000 bp: 250 kb, 500 kb and 1 Mb.
They contain 5,764, 11,590 and 22,833 variants; these are region spans,
not claims of exact 1×/2×/4× row scaling. The PLINK options match the
tutorial pipeline:
`--ld-window-kb 1000 --ld-window-r2 0.01 --r-unphased ref-based cols=id,ref,alt`
after extracting each region’s variants and retaining EUR samples (503
samples).

The chr20 VCF is 763 MiB compressed. The initial 1×/2×/4× source
conversion used 2.1 GiB on disk; `df` showed 54 GiB available before
generating derived outputs. The PGEN contains 1,647,102 chr20 variants,
but the full-chromosome LD output was not built, so its size and compute
cost are unknown. The full source and all derived data are ignored under
`work/`.

Environment: Ubuntu 24.04, Linux 6.8, Intel Core i5-13500 (20 logical
CPUs reported; 64 GiB RAM), R 4.6.0, PLINK 2 `v2.0.0-a.7.10LM` (archive
SHA-256 in `checksums.txt`), DuckDB CLI and R package 1.5.5, and DuckHTS
extension SHA-256
`9a39da4da6da65b5cc6b2a2be38b7cabfe72b493ba4a4fb59809fc581af39484`. The
DuckDB R package emitted a build-version warning because it was compiled
under R 4.6.1 and run under R 4.6.0; the parity checks completed. PLINK
was limited to 2 threads; DuckDB used its default thread setting.

## Representation and quantization

`build.sh` runs `build.sql` in the DuckDB CLI; no R is involved in the
build. `read_csv` parses the `.pvar` and `.vcor` files with explicit
column types, and each LD row resolves both endpoints on ID, REF and
ALT. The build stops if that key is not unique, if an LD row does not
resolve, or if a value is NaN (LDZip has a NaN code; these slices
contain none). `UNPHASED_R` is parsed as float32, rows with
`|r| < 0.0001` are dropped, and the float32 value is multiplied by
`(1 << (bits - 1)) - 1` in double precision and rounded half away from
zero. This is LDZip’s `std::stof`, double multiplication and
`std::llround`. The integer is stored as `TINYINT` at 8 bits and
`SMALLINT` at 16 bits, and reads divide by the scale in float32, as
LDZip’s decoder does. `COPY` writes both triangles plus any missing
diagonal cell, ordered by `(i,j)`; `variants` keeps the PVAR FILTER and
INFO columns and is ordered by index.

LDZip aborts when two variants share an ID (for example `CHROM:POS` IDs
at a multi-allelic site). The SQL build accepts them because it joins on
the full allele key: `allele_key_check.sh` rewrites the IDs to
`CHROM:POS` (171 colliding IDs in the 1× region) and gets the same `ld`
table.

Submatrix extraction filters the sorted Parquet data with
`i BETWEEN lo AND hi AND j BETWEEN lo AND hi`, fetches only stored
sparse rows, and constructs a dense R matrix by assignment with zero
fill and a unit diagonal. This is the DBI-versus-`LDZipMatrix::fetchLD`
comparison: both return a dense R matrix. The CLI cell streams the
sparse `(i,j,r)` rows to `/dev/null`; it does not construct or return a
dense matrix and is identified separately in the query table.

The layout trial used `PARQUET_VERSION V2`, ZSTD compression, four
row-group sizes and three compression levels. Each cell is the median of
three fresh build processes on the 1× region; bytes include both Parquet
files.

| Row-group rows | Zstd level | Total Parquet bytes | Median build time |
|---------------:|-----------:|--------------------:|------------------:|
|         16,384 |          3 |           1,957,196 |            0.16 s |
|         16,384 |          9 |           1,766,159 |            0.19 s |
|         16,384 |         19 |           1,559,653 |            1.78 s |
|         65,536 |          3 |           1,354,925 |            0.15 s |
|         65,536 |          9 |           1,152,781 |            0.20 s |
|         65,536 |         19 |             987,776 |            1.81 s |
|        122,880 |          3 |           1,233,128 |            0.15 s |
|        122,880 |          9 |           1,034,237 |            0.19 s |
|        122,880 |         19 |             878,243 |            1.84 s |
|        262,144 |          3 |           1,165,563 |            0.15 s |
|        262,144 |          9 |             970,046 |            0.20 s |
|        262,144 |         19 |             812,954 |            1.90 s |

The three leading size layouts were also queried in three fresh
processes each, returning dense R matrices through DBI:

| Row-group / ZSTD | 1,000-variant median / peak RSS | 5,000-variant median / peak RSS |
|------------------|--------------------------------:|--------------------------------:|
| 262,144 / 19     |                8 ms / 120.8 MiB |              179 ms / 528.2 MiB |
| 122,880 / 19     |                8 ms / 120.8 MiB |              173 ms / 527.7 MiB |
| 262,144 / 9      |                8 ms / 120.7 MiB |              174 ms / 527.9 MiB |

The chosen layout is 262,144 rows, ZSTD level 9, Parquet V2. ZSTD 19 at
the same row-group size saves 157,092 bytes (16%) on the 1× region but
takes about nine times as long to build, and the query latencies are
within a few milliseconds of each other. For this workload the level-19
build cost buys nothing at query time.

## Parity and mutation checks

`parity_regions.R` compares all reported PLINK pair values against both
LDZip decode and Parquet for each bit depth; it also checks 100 tag
queries at `r² >= 0.8`, 200 ID-resolved pairs through the SQL `variants`
join, region extraction through SQL, and complete 1,000- and
5,000-variant submatrices. Decoded float32 values are compared exactly.
The 48-variant fixture in `parity.R` independently exercises LDZip
compression and Parquet round-tripping at both bit depths.

`mutation_test.sh` edits `build.sql` with one mutant at a time, rebuilds
the 8-bit tables and requires the matching check to fail:
`parity_regions.R` against LDZip, or `allele_key_check.sh` for the
allele join. LDZip requires unique IDs, so an ID-only join cannot change
anything LDZip parity sees; the `CHROM:POS` rewrite is what exposes it.
A mutant that leaves the SQL unchanged or breaks the build is a harness
error, not a kill. `test.sh` runs the whole pipeline and the mutants in
CI on a committed 500-variant slice of the 1× region (`fixtures/`, 69
KB); the same mutants were also run on the full 1× region.

| Check                                                                                 | Result                                                                 |
|---------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| 48-variant fixture, 8-bit and 16-bit quantization and Parquet round-trip              | PASS                                                                   |
| Full PLINK pair values, 8-bit and 16-bit                                              | PASS for 336,425 / 733,100 / 1,806,989 emitted pairs at 1× / 2× / 4×   |
| `getNeighbors`, 100 variants at `r² >= 0.8`                                           | PASS at both bit depths and all three region sizes                     |
| SQL ID and region lookups                                                             | PASS against LDZipMatrix at both bit depths and all three region sizes |
| 1,000- and 5,000-variant dense submatrices                                            | Exact PASS at both bit depths and all three region sizes               |
| Wrong rounding, shifted index, upper triangle only, wrong threshold, missing diagonal | Each fails parity on the CI slice and the 1× region                    |
| ID-only join (allele template ignored)                                                | Fails `allele_key_check.sh`: 1,170,740 rows instead of 678,614 at 1×   |

## Performance

Budgets declared before the repeated measurements: at most 300 seconds
wall time, 16 GiB peak RSS, and 10 GiB temporary output per process. The
initial `df` check showed about 54 GiB available; after the benchmark,
50 GiB remained with 3.5 GiB under `work/`. Each build and query cell
runs in three fresh processes. `measure_build.sh` captures elapsed time,
peak RSS and per-run output bytes for `ldzip compress` and for
`build.sh` (one DuckDB CLI process). The SQL build time includes CSV
parsing, allele-key resolution, quantization and both Parquet writes.
Query RSS for CLI is measured in its child process; LDZip and DBI RSS is
for the R process.

### Size

Matrix: LDZip’s value, index and pointer files with their index files,
against the Parquet `ld` table. Variant metadata: LDZip’s `.vars.txt`
and SQLite index, against the Parquet `variants` table; both keep the
PVAR FILTER and INFO fields.

| Region | Bits | LDZip matrix | Parquet `ld` | LDZip `.vars.txt` + `.sqlite` | Parquet `variants` |
|--------|-----:|-------------:|-------------:|------------------------------:|-------------------:|
| 1×     |    8 |    705,768 B |    486,632 B |                   7,312,668 B |          483,414 B |
| 1×     |   16 |  1,001,500 B |  1,146,838 B |                   7,312,668 B |          483,414 B |
| 2×     |    8 |  1,776,794 B |  1,736,252 B |                  14,638,863 B |          984,359 B |
| 2×     |   16 |  2,578,907 B |  3,325,079 B |                  14,638,863 B |          984,359 B |
| 4×     |    8 |  4,551,222 B |  4,524,338 B |                  28,725,646 B |        1,850,275 B |
| 4×     |   16 |  6,406,716 B |  8,023,822 B |                  28,725,646 B |        1,850,275 B |

At 8 bits the Parquet `ld` table is smaller than LDZip’s matrix files at
1× and about the same at 2× and 4×. At 16 bits it is larger at every
scale. LDZip keeps the variant list as plain text, so the compressed
Parquet `variants` table is 15 times smaller. These are stored bytes;
they do not say the formats or their indexes are equivalent.

### Build

Medians of three fresh processes, at the chosen layout.

| Region | Bits | `ldzip compress` time / peak RSS | `build.sh` time / peak RSS |
|--------|-----:|---------------------------------:|---------------------------:|
| 1×     |    8 |                 0.14 s / 9.3 MiB |         0.21 s / 182.7 MiB |
| 2×     |    8 |                0.31 s / 12.3 MiB |         0.32 s / 324.4 MiB |
| 4×     |    8 |                0.79 s / 18.6 MiB |         0.57 s / 644.8 MiB |
| 1×     |   16 |                 0.14 s / 8.9 MiB |         0.21 s / 188.1 MiB |
| 2×     |   16 |                0.32 s / 12.4 MiB |         0.33 s / 333.6 MiB |
| 4×     |   16 |                0.80 s / 18.8 MiB |         0.60 s / 665.6 MiB |

The SQL build is slower at 1×, level at 2× and faster at 4×. It uses 20
to 35 times LDZip’s peak memory; DuckDB ran with its default threads and
memory limit.

### 5,000-variant extraction

The DBI path fetches only the stored pairs inside the index bounds and
fills a dense R matrix. The CLI path streams the sparse rows and does
not build a dense matrix.

| Region | Bits | DBI sparse fetch + dense R matrix | CLI sparse stream | LDZip dense R matrix |
|--------|-----:|----------------------------------:|------------------:|---------------------:|
| 1×     |    8 |                  189 ms / 528 MiB |    50 ms / 74 MiB |     107 ms / 318 MiB |
| 2×     |    8 |                  197 ms / 531 MiB |    50 ms / 76 MiB |     107 ms / 320 MiB |
| 4×     |    8 |                  189 ms / 535 MiB |    50 ms / 81 MiB |     111 ms / 322 MiB |

LDZip returns the dense matrix faster and with less memory.

### Query latency

Values are medians of three fresh processes. Cells are milliseconds /
MiB. Pair queries use fixed-seed random indices; tag queries contain 100
distinct variants; the submatrix operations return dense R matrices for
DBI and LDZip. The CLI submatrix cell streams sparse rows to `/dev/null`
and is not semantically the same output operation.

| Region | Bits | Query               |     LDZip R |  DuckDB DBI | DuckDB CLI |
|--------|-----:|---------------------|------------:|------------:|-----------:|
| 1×     |    8 | 1,000 random pairs  |  35 / 127.8 |  16 / 114.4 |  20 / 40.4 |
| 1×     |    8 | 10,000 random pairs | 335 / 128.0 |  24 / 115.4 |  20 / 41.9 |
| 1×     |    8 | 100 tag queries     | 225 / 128.9 |  35 / 136.8 |  40 / 63.9 |
| 1×     |    8 | 1,000 submatrix     |   4 / 135.5 |   8 / 120.8 |  10 / 30.2 |
| 1×     |    8 | 5,000 submatrix     | 107 / 318.2 | 189 / 528.1 |  50 / 73.6 |
| 1×     |   16 | 1,000 random pairs  |  44 / 127.6 |  16 / 115.4 |  20 / 41.9 |
| 1×     |   16 | 10,000 random pairs | 410 / 128.2 |  25 / 116.9 |  30 / 43.3 |
| 1×     |   16 | 100 tag queries     | 222 / 129.2 |  34 / 137.3 |  40 / 64.2 |
| 1×     |   16 | 1,000 submatrix     |   4 / 135.4 |   9 / 120.6 |  10 / 30.3 |
| 1×     |   16 | 5,000 submatrix     | 105 / 318.4 | 192 / 528.4 |  50 / 77.2 |
| 2×     |    8 | 1,000 random pairs  |  45 / 129.3 |  18 / 119.2 |  20 / 45.0 |
| 2×     |    8 | 10,000 random pairs | 434 / 129.5 |  30 / 120.1 |  30 / 45.9 |
| 2×     |    8 | 100 tag queries     | 228 / 130.4 |  24 / 128.4 |  30 / 53.7 |
| 2×     |    8 | 1,000 submatrix     |   4 / 136.9 |   9 / 120.9 |  10 / 30.2 |
| 2×     |    8 | 5,000 submatrix     | 107 / 320.0 | 197 / 531.3 |  50 / 75.5 |
| 2×     |   16 | 1,000 random pairs  |  55 / 129.5 |  19 / 123.1 |  20 / 48.3 |
| 2×     |   16 | 10,000 random pairs | 546 / 129.2 |  28 / 122.6 |  30 / 49.3 |
| 2×     |   16 | 100 tag queries     | 245 / 131.1 |  23 / 127.4 |  30 / 55.3 |
| 2×     |   16 | 1,000 submatrix     |   4 / 137.1 |   9 / 122.1 |  10 / 30.3 |
| 2×     |   16 | 5,000 submatrix     | 106 / 320.4 | 186 / 531.8 |  50 / 80.9 |
| 4×     |    8 | 1,000 random pairs  |  58 / 131.1 |  19 / 130.0 |  20 / 55.6 |
| 4×     |    8 | 10,000 random pairs | 560 / 130.8 |  30 / 131.5 |  30 / 57.7 |
| 4×     |    8 | 100 tag queries     | 241 / 132.1 |  30 / 143.8 |  40 / 72.6 |
| 4×     |    8 | 1,000 submatrix     |   4 / 138.3 |   9 / 123.3 |  20 / 30.9 |
| 4×     |    8 | 5,000 submatrix     | 111 / 321.8 | 189 / 535.1 |  50 / 81.4 |
| 4×     |   16 | 1,000 random pairs  |  71 / 131.1 |  20 / 135.7 |  20 / 63.1 |
| 4×     |   16 | 10,000 random pairs | 700 / 131.2 |  30 / 137.3 |  30 / 64.2 |
| 4×     |   16 | 100 tag queries     | 230 / 132.1 |  33 / 147.9 |  30 / 76.7 |
| 4×     |   16 | 1,000 submatrix     |   4 / 138.9 |  10 / 124.3 |  20 / 30.9 |
| 4×     |   16 | 5,000 submatrix     | 107 / 321.9 | 190 / 536.5 |  40 / 82.7 |

DBI and CLI execute the same SQL for pair and tag queries against the
same generated inputs. CLI timing includes starting DuckDB; DBI reuses
its connection within each fresh R process. All measured cells stayed
within the declared wall-time, RSS and temporary-output budgets.

### Comparator limits

The pair SQL returns nullable quantized `r_q`, while LDZip returns
decoded correlations and zero-fills absent pairs. The LDZip pair path
sorts by row index, although its native API batches adjacent column
indices; a fair batched comparator needs `order(query$j, query$i)` and
restoration of query order. The large pair gap does not establish an
inherent SQL advantage.

The tag comparison is one SQL batch against 100 `getNeighbors()` calls,
including LDZip’s SQLite-based resolution. The SQLite index is required
but its construction is excluded from compression timing and not
performed by `measure_queries.sh`. Dense DBI extraction is a same-value
comparison, but its R diagonal assignment copies the full matrix. The
[performance review](REVIEW.md) has the allocation and pair-grouping
diagnostics. The separate [native report](NATIVE_REPORT.md) measures
SQL-resident matrices, direct C-buffer consumption and resource failures
under explicit 1/4-thread settings. Its output representations differ
from this DBI workload; it does not measure GEMM performance.

## Contrast and limits

One SQL file reproduces LDZip’s quantized matrix exactly at both bit
depths in every tested region, and the stored pairs, allele-aware
variant keys, joins and genomic predicates stay composable in SQL. The
pair and tag timings do not establish equivalent-workload speedups: they
use different batching, value contracts and setup work. The Parquet
variant table is about 15 times smaller than LDZip’s text and SQLite
index. LDZip is faster and leaner for dense 1,000- and 5,000-variant
extraction, builds with far less memory, builds faster at the smallest
scale, and stores a smaller 16-bit matrix. CLI sparse streaming returns
sparse `(i,j,r)` rows, not a dense matrix.

## Reproduction

``` sh
cd demos/ldzip
./test.sh
./full_test.sh
./measure_layouts.sh
./measure_build.sh
./measure_queries.sh
```
