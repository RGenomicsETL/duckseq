# Real PBMC evidence

The public 10x Cell Ranger 3.0.0 `pbmc_1k_v3` BAM has 4,785,553,644 bytes and SHA-256 `e144691486ce459666e985ee98b26961fdb53ede866578824e87fb5df36efb25`. `acquisition.http` records the conditional HTTPS acquisition; `source-input-hash.txt` and `derived-input-hashes.txt` identify the source and nested 1M/2M/4M primary-record BAMs. The large BAMs are rebuildable inputs, not repository payloads.

`source/` holds the measured harness, SQL, derivation and declared protocols. Source/derived BAMs were on tmpfs; prepared states were on the local filesystem. Inputs contain mapped primary nonsupplementary NH=1 records with CB/UB/CR/UR present. These are restricted real-cohort prefixes, not the whole cohort.

## Measurements

`raw.tsv` has 144 complete CLI measurements: preparation, full-chr1 and fixed 3 Mb queries, one/four threads and three fresh processes per cell. Every row passes the declared resource budgets. Preparation representations and counting policies differ; these are capability/cost contrasts, not equal-output speedups. Short query timings are diagnostics, not STYLE qualification.

Each row's `stem` identifies adjacent `.out`, `.log` and `.time` receipts. `.time` contains GNU time's whole-process peak RSS in KiB; elapsed time is the R parent interval including child launch, execution and output writing. Prepared bytes, returned cell rows and count sums are recorded. Runtime versions are in `environment.txt`; loaded binaries are identified by `runtime-artifact-hashes.txt`.

Gravlax consumes raw barcode/UMI evidence and constructs its UMI classes. The product trusts supplied CB and uses raw UR to expose exact-label and overlap-connected family counts. All input CB values have the single-GEM-group `DNA16-1` form; the comparator whitelist projects those keys to DNA16 without changing counts. It is an observed-barcode whitelist, not a chemistry whitelist or a validated cell-calling policy.

## Independent admission

`admission/` contains samtools/awk reference and product outputs for the full-chr1 and 3 Mb raw-label queries on the 4M input. Both `.diff` files are empty. The separate query profile shows cached-table evaluation rather than per-query CIGAR parsing. The product's scalar CIGAR and pairwise interval-graph fixture tests reject four semantic mutants and require restored SQL to pass; baseline/restored logs are retained.

`bd7352ba2.output` is the real measurement completion receipt; `ba9b64d37.output` records independent real-label admission. `be74517b8.output` records the separate nine-mutant compatibility suite and peakwhere server regressions. Compatibility fixtures do not define the product's default biological policy.

`SHA256SUMS` covers every published file except itself. No whole-cohort annotation performance, general multimapper performance or full STYLE qualification is established by this archive.
