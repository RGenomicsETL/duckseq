# Real PBMC serving-cache experiment

Source: public 10x Cell Ranger 3.0.0 `pbmc_1k_v3` BAM, 4,785,553,644 bytes. Pin the observed publisher ETag before acquisition and record the full downloaded SHA-256, input lengths, command/runtime hashes and source snapshots. The HTTP pilot and its derivation are in `evidence/real-pilot/`.

## Genuine input sizes

Derive nested **1,000,000 / 2,000,000 / 4,000,000 primary alignment records** from one ordered pass, without duplicating records or barcodes. Retain mapped, nonsupplementary NH=1 records with CB/UB/CR/UR present. These are restricted real-cohort prefix workloads, not whole-cohort or general multimapper benchmarks. Record counts, cell counts, genomic coverage and prepared bytes.

Use the product contract in `COUNTING_CONTRACT.md`: supplied CB and raw UR, with separate exact-label and overlap-family queries. Gravlax receives the same BAM and a declared whitelist; it makes its own raw-barcode/UMI-classing decisions. Record and inspect differences; do not advertise an equal-output speedup for different policies.

## Budgets, before acquisition/measurement

- One source download, at most 6 GiB, placed in an owned temporary cache. HTTPS source is fixed by ETag; timeout 20 minutes. No automatic overwrite of prior receipts.
- Each derived BAM: at most 2 GiB; combined source/derived data at most 12 GiB. Derivation wall ceiling 10 minutes.
- Each preparation/query process: 180 seconds and 4 GiB peak RSS. DuckDB buffer 2 GiB; spill at most 2 GiB. Prepared state at most 4 GiB per cell.
- Threads: explicitly one and four for both DuckDB and Gravlax's Rayon pool. BLAS/OpenMP one. Three fresh processes per cell, serialized. Preserve failures; no retries replacing failed receipts.
- Preparation and query costs are separate. Measure complete CLI startup, state opening, evaluation and output writing. Report raw latency, RSS and prepared bytes. Short single queries remain diagnostics; do not create thousands of CLI launches to imply a large workload or a timing verdict under STYLE.
- The real source may be in tmpfs; disclose that storage medium. Do not mix acquisition/derivation time with engine preparation. Do not run competing benchmark/test processes during measurement.

Admission of our product requires its independent scalar/mutation tests. Gravlax differences are audited against the declared policies; matching every upstream-specific policy is not a product requirement. Whole-cohort annotation performance and full STYLE compliance remain unverified unless actually measured.
