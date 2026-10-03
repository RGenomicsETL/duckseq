# Native dense LD benchmark protocol

## Question and endpoints

Measure dense LD matrix construction and full-value consumption inside DuckDB using (1) built-in SQL and (2) a DuckTinyCC native aggregate. A separately labelled LDZipMatrix endpoint returns and consumes an R matrix. This tests assembly, not GEMM and not a zero-copy transport claim. R may orchestrate queries and receive scalar metrics; SQL endpoints must not materialize matrix values in R.

The public chr20 tutorial's existing `region-4x` artifacts are the fixed source, at both 8 and 16 bits. Requested leading-window dimensions are 1,000, 2,000 and 4,000 variants (1×/2×/4× in each matrix axis, with 1×/4×/16× required output cells). This is a matrix-dimension ladder, not a file-row-count scaling claim or full-chromosome run. Source hashes and selected stored-cell counts must be recorded. A separate 5,000-variant, 16-bit checkpoint uses the same process, thread, duration and byte-budget formulas to connect to the earlier dense-extraction workload; it is not another input-ladder point.

## Measurement declared before runs

- Engines: built-in SQL, DuckTinyCC aggregate, LDZipMatrix compatibility endpoint.
- Threads: 1 and 4 for DuckDB; LDZipMatrix is single-threaded and reported once per size/bit-depth rather than duplicated as a four-thread implementation. Cap BLAS/OpenMP threads to one; no BLAS kernel is tested.
- Three fresh R processes per engine/size/bit-depth/thread cell; serialize all measured processes, with agents and other performance tests stopped first.
- Each process repeatedly constructs, retains, consumes and releases one complete dense result until at least 5 seconds of measured execution have elapsed. Record iterations, total measured seconds and per-operation average for each process; report the median and min/max of those three process averages. Do not call these individual-operation medians.
- Record the first operation separately. Fresh processes do not imply a cold operating-system page cache. Files are pre-staged; OS cache is not flushed. Repeated operations are intentionally warm. A DuckDB connection is reused within the process; registration and one-time setup are excluded from the execution timer and reported separately. Whole-process elapsed time and peak RSS include setup.
- Both SQL endpoints retain `j, vals DOUBLE[]` columns for a complete dense matrix in a temporary table. Consume every matrix cell with `list_sum(vals)` and retain dimensions plus the scalar checksum. LDZipMatrix constructs its complete R matrix and consumes all values with `sum()`. Do not use `count(*)` as the only consumer.
- Correctness is checked separately from measured processes by exact value comparison, including zero fill and unit diagonal. Timed checksums are consumption guards, not substitutes for exact parity tests.
- DuckDB buffer limit: 1 GiB. Temp/spill limit: 512 MiB. One complete dense SQL grid has two 64-bit coordinates and one double per cell; its dense output adds one double. Declare the RSS ceiling as 512 MiB runtime allowance plus three times this 32-byte-per-cell decoded live-state bound: 604 MiB at 1,000, 879 MiB at 2,000, and 1,977 MiB at 4,000 (ceilings calculated from bytes, not rounded labels). Use the same ceiling for every engine at a given size. A breach is a failed budget, not a reason to raise the ceiling.
- Per-process wall timeout: 60 seconds, including setup, repeated operations and diagnostic profiling. No per-cell generated output is saved. Raw metric logs and one final profile per measured process are capped at 10 MiB each. Record DuckDB peak buffer memory and spill bytes from profiling, distinct from whole-process peak RSS. Native allocations are not necessarily included in DuckDB buffer accounting.
- Record R, DuckDB, LDZip and DuckTinyCC versions/artifact identity, CPU/OS, environment/thread controls, query texts, and input/output dimensions. DuckTinyCC runtime compilation is trusted unsandboxed code, and its allocator/result-copy costs remain part of the measured implementation.

## Native-buffer boundary diagnostic

A separate diagnostic at 5,000 variants/16-bit uses 1 and 4 DuckDB threads, three fresh processes and at least five measured seconds per process, with the same memory, spill, RSS and wall ceilings. It reuses the selected-cell state and full dense-column construction, then consumes every element in C and returns only a scalar column checksum. The temporary C buffer is released inside the native final callback. Record its generated C source, last-operation profile and whole-process RSS independently from the matrix endpoint measurements.

This isolates the effect of native-to-DuckDB composite output and SQL matrix retention. It does not return a complete retained matrix, is not interchangeable with the matrix endpoints, and cannot establish a GEMM or matrix-export speedup. Scalar checksums are checked against independently decoded sparse values plus the unit diagonal; complete decoded-value correctness belongs to the matrix admission tests.

## Claims and limits

The same decoded values do not imply the same consumer representation: SQL-resident dense columns and an R matrix are distinct endpoints. Compare the two SQL implementations directly; describe LDZipMatrix as compatibility context, not an interchangeable SQL endpoint. Short first-operation measurements alone receive no latency verdict. A failed path, budget or parity check must be reported, not silently omitted.

The experiment does not measure a streaming chunk-to-GEMM pipeline, downstream linear algebra, final SQL-to-R matrix transfer, cold-cache latency, arbitrary genomic windows, tag/pair lookups or whole-chromosome scale. Those remain separate questions.
