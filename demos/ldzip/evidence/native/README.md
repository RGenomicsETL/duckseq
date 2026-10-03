# Native LD measurement evidence

These local snapshots support `../../NATIVE_REPORT.md`.

- `ladder/`: 90 fresh processes at 1,000/2,000/4,000 variants, 8/16 bits and declared 1/4 SQL threads; raw and grouped metrics, environment/source/input hashes, profiles and logs.
- `checkpoint/`: 15 fresh processes at 5,000 variants/16-bit under the same limits.
- `boundary/`: six fresh 5-second native-buffer consumption diagnostics, including generated C source, profiles, GNU time receipts and raw metrics. Their scalar output is not a retained matrix.
- `native-admission.tsv`: exact-value admission and explicit SQL resource failures; standalone mutation/failure checks are reported by `check_native.R`.
- `source/`: kernels and checks associated with the evidence. `measure_native_at_run.R` in each matrix directory preserves the measured harness.
- `blas-link.txt`: exact small-DGEMM checks via explicit linking and `dlopen()` of R's actual BLAS provider; not a performance result.
- `SHA256SUMS`: integrity manifest, checked from the repository root with `sha256sum -c demos/ldzip/evidence/native/SHA256SUMS`.

Raw log/profile paths identify the original local workspace. The corresponding files are preserved within each snapshot directory. Peak RSS covers each whole process; profiles describe one additional post-timing construction operation, not the entire measured repetition interval. Failed allocations have no valid completed profile. The SQL budget failures remain in the raw and summary tables.

The matrix output endpoints differ: SQL returns retained dense `DOUBLE[]` columns; LDZip returns an R matrix. The direct-buffer diagnostic constructs/consumes full columns but returns scalar checksums. No receipt here measures GEMM throughput, a query-chunk-to-BLAS pipeline, zero-copy matrix transport or a final R-matrix handoff.
