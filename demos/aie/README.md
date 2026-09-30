# Gravlax evidence in DuckDB SQL

This workspace probes whether BAM-derived evidence can be represented as typed Parquet relations and queried with DuckDB/DuckHTS SQL. Gravlax is pinned at `75b8d6c01064ba92af295543d50230429774e170`; the oracle was built from source with Cargo and reports `aie 0.2.3`.

## Run

From this directory, run:

```sh
./setup.sh
./test.sh
./mutation_test.sh
```

Setup obtains the DuckDB CLI and DuckHTS extension, then clones and builds Gravlax at the recorded commit. Set `DUCKDB` or `DUCKHTS_EXTENSION` to use local alternatives. The tests regenerate the reference, BAMs, indexes, Gravlax archives and Parquet files; run SQL and matching Gravlax region, junction, jset, replay, and annotation-comparison operations; and require all seven SQL mutants to be killed. Requirements: git/network access, Rust/Cargo, R, samtools, jq, curl and unzip. `EXTENSIONS.txt` records the resolved versions and extension checksum after setup.

`fixture/README.md` documents each alignment. `SCHEMA.md` describes relation keys, ordering, coordinate conventions, and unavailable information. SQL is in `sql/`.

## Current oracle result

The fixture-scoped region, junction and jset results agree exactly with Gravlax for both samples. Annotation replay and signed annotation deltas also match for both annotation versions. Seven mutation tests kill altered rules in the annotation SQL. These results are scoped to the checked-in synthetic fixture and do not establish exhaustive compatibility or performance parity.

## Semantics and limitations

The source resolves the main apparent geometry ambiguity: Gravlax's alignment decomposition merges across `D` and records `N` as a junction (`.gravlax/crates/ingest/src/cigar.rs:34-68`); DuckHTS `cigar_aligned_blocks` splits at either operation, so the Parquet geometry retains both those blocks and the ordered CIGAR operation tokens. Gravlax's annotation assignment requires every splice junction to match consecutive transcript exon boundaries exactly, and only unique genes with `NH == 1` qualify for the unique-assignment rule (`.gravlax/crates/anno/src/assign.rs:8-17,321-322`). The current SQL does not yet implement that rule.

Gravlax builds loci by single-linkage read-start distance, then collapses one-mismatch UMIs by descending abundance, with deterministic value ordering for ties (`.gravlax/crates/aie/src/build.rs:7-13,240-257,274-310`). Its archive molecule count is therefore not equivalent to raw distinct-UMI count in every case. Placement alternatives are retained with `NH`/`HI` and descriptive weights in SQL; converting those weights into Gravlax's locus/representative selection is not implemented.

Availability rows distinguish absent evidence from measured zero. The SQL does not infer a biological zero from missing BAM evidence. The fixture uses short synthetic sequence and is an oracle fixture, not performance evidence. Scale measurements, public data staging, richer positive-jset coverage, exact annotation replay, and full cell/UMI correction parity remain undone.
