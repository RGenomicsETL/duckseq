
# duckseq

**Genomics keeps writing its own file formats, parsers and query
engines. Most of them are not needed.** Standard formats (Parquet,
DuckLake), DuckDB SQL over
[DuckHTS](https://github.com/RGenomicsETL/duckhts) readers, and the
occasional small native kernel give the same answers.

duckseq shows this one tool at a time. Each demo takes a tool that was
built by hand and holds to four rules:

- **Exact parity:** the same answers on the tool’s own tests or
  tutorial.
- **Mutation tests:** the comparison fails when a rule is implemented
  wrong, so passing means something.
- **Measured performance:** DuckHTS `STYLE.md` rules, with 1×, 2× and 4×
  inputs, three fresh processes, peak RSS, and budgets declared before
  measuring.
- **An honest contrast:** including where the original tool wins.

| Demo                                                           | Original tool                                        | What is compared                                                                                               | Status and headline result                                                                                                                                                                                                            |
|----------------------------------------------------------------|------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [peakwhere](https://rgenomicsetl.github.io/duckseq/peakwhere/) | peakwhere and PeakPeek; ChIPseeker for the benchmark | Peak annotation and peak-file summaries against checked fixtures, hand-worked results and ChIPseeker           | Exact output against the independent W1 oracle (7,220 peaks). Native DuckDB totals 0.401 s (1 thread) / 0.370 s (multithreaded), versus ChIPseeker’s 2.776 s; native multithreaded peak RSS is 335 MiB versus ChIPseeker’s 1,198 MiB. |
| [AIE](https://rgenomicsetl.github.io/duckseq/aie/)             | Gravlax AIE 0.2.3                                    | Region, junction, jset and annotation replay counts on the checked-in synthetic fixture                        | Exact parity for both samples, including seven mutation tests; no performance benchmark yet.                                                                                                                                          |
| [LDZip](https://rgenomicsetl.github.io/duckseq/ldzip/)         | LDZip / LDZipMatrix                                  | PLINK 2 LD matrices represented by quantized values and allele-aware variant lookups in Parquet and DuckDB SQL | Chr20 1000 Genomes tutorial data; results and the measured scope are in the [LDZip report](https://github.com/RGenomicsETL/duckseq/blob/main/demos/ldzip/REPORT.md).                                                                  |

The peakwhere numbers are from its [performance
report](https://github.com/RGenomicsETL/duckseq/blob/main/demos/peakwhere/benchmarks/performance.md).
See the [AIE
report](https://github.com/RGenomicsETL/duckseq/blob/main/demos/aie/REPORT.md)
and [LDZip
report](https://github.com/RGenomicsETL/duckseq/blob/main/demos/ldzip/REPORT.md)
for fixture scope and limits. Performance coverage is not yet complete
across the 1×/2×/4× protocol; do not infer a general speed or memory
advantage from the reported cases.

## Run a demo

Peakwhere runs in a browser with its vendored DuckDB-Wasm and DuckHTS
builds:

``` sh
cd demos/peakwhere
npm ci
npm run stage && npm run stage:peek && npm run vendor
npm run serve
npm test
```

AIE builds its pinned Gravlax oracle and obtains the DuckDB CLI and
DuckHTS extension on first run. Requirements include Rust/Cargo, R,
samtools, jq, curl and unzip:

``` sh
cd demos/aie
./setup.sh
./test.sh
./mutation_test.sh
```

LDZip’s small CI fixture check needs R, a C++ toolchain, `make`, `curl`
and `unzip`:

``` sh
cd demos/ldzip
./setup.sh --no-data
./test.sh
```

The full chr20 benchmark downloads the tutorial VCF and builds nested
regions:

``` sh
cd demos/ldzip
./full_test.sh
./measure_build.sh
./measure_queries.sh
```

The Pages site is <https://rgenomicsetl.github.io/duckseq/>. Peakwhere
runs at
[/peakwhere/](https://rgenomicsetl.github.io/duckseq/peakwhere/), with
reports at [/aie/](https://rgenomicsetl.github.io/duckseq/aie/) and
[/ldzip/](https://rgenomicsetl.github.io/duckseq/ldzip/).

## Licensing

The repository is GPL-2.0-or-later. `demos/peakwhere` retains its MIT
licence. Gravlax is BSD-3-Clause and is built from its pinned upstream
source; it is not vendored. See each demo’s source and licence notices
for data and upstream attribution.
