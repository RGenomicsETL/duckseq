# Gravlax / DuckDB query benchmark

## Input and admission

Use the demo's corrected BAM fixture topology, repeated under 1,024 / 2,048 / 4,096 distinct 16-base cell barcodes. Each cell receives the same records, with unique read names and unchanged CIGAR, strand, UMI, NH and HI values. These are exact 1×/2×/4× record-count inputs. The reference remains the synthetic 120-base chr1 fixture; this is not a whole-transcriptome workload.

Both engines receive the same sorted BAM. Gravlax uses the pinned upstream `75b8d6c01064ba92af295543d50230429774e170` archive; DuckDB uses DuckHTS and the demo's relational preparation. The sample_b BAM is empty for this single-cohort workload. Preparation output representations differ and their costs/storage are reported separately.

Admission requires complete cell/count parity against Gravlax for region `chr1:1-100` and junction `chr1:14-24` at every size. The correctness suite separately covers later junctions, multi-placement reads, jset and annotation replay. Performance claims here cover only the two admitted count queries.

## Measurement

- Three independent measurement batches per engine, input size, operation and thread count (one and four), serialized with no other benchmark or test processes running. Set DuckDB `threads` and Gravlax `RAYON_NUM_THREADS` explicitly.
- Each batch accumulates at least five measured seconds from repeated fresh CLI invocations. Time the complete invocation, including startup, opening persisted input, query evaluation and writing all cell/count rows. No process-resident reuse and no hidden retry.
- R's elapsed process clock measures wall latency; GNU time records whole-process peak RSS. Preserve stdout, stderr, exit status and time receipts. Verify results outside the timer.
- Report the median/range of the three batch-average invocation latencies and maximum CLI RSS in each batch. Preserve every invocation's output, error stream, RSS and elapsed value. Verification occurs between invocations, outside the timer.
- Preparation also uses three fresh processes; each writes to an isolated destination. Include input and prepared-output bytes and tool/input/source hashes.

## Budgets declared before measurement

Each process has a 120-second wall ceiling and a 2 GiB peak-RSS ceiling. DuckDB uses the declared one/four threads, a 1 GiB buffer limit and at most 512 MiB spill. Prepared output per engine/run is capped at 2 GiB; each stdout/stderr receipt is capped at 64 MiB. BLAS/OpenMP thread counts are one. A timeout, nonzero exit, mismatched result, missing receipt or budget breach fails the cell and remains visible. Do not substitute zero for a failed timing or drop a failed run.

Charts must distinguish equivalent count-query outputs from different preparation representations. Show latency and RSS with ranges; do not compare this synthetic fixture to published real-cohort throughput claims. Annotation replay, jset performance, browser execution and larger genomic geometries are unmeasured in this protocol. This synthetic repeated-CLI diagnostic does not establish DuckHTS STYLE operating-scale compliance: the individual 1× query is shorter than five seconds and no public transcriptome workload is included.
