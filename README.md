# Gravlax evidence in DuckDB SQL

This workspace probes whether BAM-derived evidence can be represented as typed Parquet relations and queried with DuckDB/DuckHTS SQL. Gravlax is pinned at `75b8d6c01064ba92af295543d50230429774e170`; the oracle was built from source with Cargo and reports `aie 0.2.3`.

## Run

From `/root/aie-sql`, run:

```sh
./test.sh
```

The command regenerates the reference, SAM-derived BAMs, indexes, Gravlax archives and Parquet files; runs the SQL and matching Gravlax region, junction, jset, replay, and annotation-comparison operations. It exits nonzero when the current annotation SQL disagrees with Gravlax rather than treating the difference as acceptable. Requirements: git/network access for the first Gravlax clone, Rust/Cargo, samtools, jq, `/root/.local/bin/duckdb` 1.5.1, and the pinned extension `ext/duckhts.duckdb_extension`.

`fixture/README.md` documents each alignment. `SCHEMA.md` describes relation keys, ordering, coordinate conventions, and unavailable information. SQL is in `sql/`.

## Current oracle result

The fixture-scoped region and junction queries agree exactly with Gravlax for both samples: four region UMI classes and two junction UMI classes per cell. This is not evidence of general parity with Gravlax's locus and UMI-collapse policy. The SQL jset include-only count agrees with Gravlax's `2`; the fixture has no exclusion junction, so it does not test a positive same-molecule `both` class or a separate-molecules false positive.

Annotation replay is not yet equivalent. On sample A, Gravlax replay gives v1 `geneA=1, geneB=1` and v2 `geneB=1`; `compare-annotations` reports a signed `geneA` delta of `-1`. The exploratory SQL overlap query gives v1 `geneA=3` and v2 `geneA=3, geneC=3`; it misses `geneB=1` in both versions. SQL counts overlapping exon blocks and distinct exact UMIs; it does not yet implement transcript-concordant assignment, Gravlax's 1-mismatch UMI collapse, or alternative-placement assignment. The test reports this mismatch and exits nonzero.

## Semantics and limitations

The source resolves the main apparent geometry ambiguity: Gravlax's alignment decomposition merges across `D` and records `N` as a junction (`.gravlax/crates/ingest/src/cigar.rs:34-68`); DuckHTS `cigar_aligned_blocks` splits at either operation, so the Parquet geometry retains both those blocks and the ordered CIGAR operation tokens. Gravlax's annotation assignment requires every splice junction to match consecutive transcript exon boundaries exactly, and only unique genes with `NH == 1` qualify for the unique-assignment rule (`.gravlax/crates/anno/src/assign.rs:8-17,321-322`). The current SQL does not yet implement that rule.

Gravlax builds loci by single-linkage read-start distance, then collapses one-mismatch UMIs by descending abundance, with deterministic value ordering for ties (`.gravlax/crates/aie/src/build.rs:7-13,240-257,274-310`). Its archive molecule count is therefore not equivalent to raw distinct-UMI count in every case. Placement alternatives are retained with `NH`/`HI` and descriptive weights in SQL; converting those weights into Gravlax's locus/representative selection is not implemented.

Availability rows distinguish absent evidence from measured zero. The SQL does not infer a biological zero from missing BAM evidence. The fixture uses short synthetic sequence and is an oracle fixture, not performance evidence. Scale measurements, public data staging, richer positive-jset coverage, exact annotation replay, and full cell/UMI correction parity remain undone.
