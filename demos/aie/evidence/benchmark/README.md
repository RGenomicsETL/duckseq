# Controlled synthetic CLI diagnostics

`raw.tsv` combines the two one/four-thread controlled runs (`t1-raw.tsv`, `t4-raw.tsv`): 108 passing batches. Each batch accumulates at least five measured seconds through fresh CLI invocations. These are short-query diagnostics, not individual operating-scale workloads or full STYLE qualification.

Inputs use 1,024/2,048/4,096 distinct synthetic cell keys and the recorded 28-alignment template: 28,672/57,344/114,688 records on a nominal 120-base BAM reference. No claims of realistic whole-transcriptome throughput follow from those inputs. `source/` preserves the template, SQL, harness and protocol used by the measurement; it is distinct from the current compatibility fixture.

`t1-receipts.tar.zst` and `t4-receipts.tar.zst` preserve each invocation's stdout, stderr and time receipt, iteration tables, preparation logs, verification data, generated SQL and runtime/input metadata. Their archive paths retain the original workspace layout. They exclude rebuildable BAM/Parquet/AIE caches and copied extension binaries. Decode with `tar --zstd -xf t1-receipts.tar.zst` and likewise for t4; `zstd` is required. The archives were decompression-tested and byte-compared against every selected original file.

The uncontrolled preliminary thread-pool run is not used by these charts. These diagnostics preserve unfavorable latency/RSS results; they are separate from the real PBMC experiment in `../real/`.

`SHA256SUMS` covers every file here except itself. See `../../BENCHMARK_PROTOCOL.md` and `../../REPORT.md` for budgets, endpoints and limitations.
