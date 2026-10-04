# Queryable alignment evidence

DuckHTS reads standard BAM; DuckDB materializes inspectable observations, reference geometry, splice junctions and overlap-connected evidence families. The default trusts supplied CB and uses raw UR. Raw CR/UR and corrected CB/UB remain distinct. Exact UMI labels, evidence families and Gravlax classes have different count meanings; none is silently treated as the same physical-molecule estimate.

See the [counting contract](COUNTING_CONTRACT.md) and [real PBMC product report](PRODUCT_REPORT.md). The real 1M/2M/4M-record experiment uses three fresh processes at one/four threads: 144 CLI processes pass declared resource budgets. Full-chr1 and 3 Mb raw-label counts on the 4M-record input also match independent samtools/awk. Full-cohort annotation and general multimapper performance are unverified.

## Product cache

```sh
./prepare_evidence.sh /path/to/input.bam work/input.duckdb sample UR 4
duckdb work/input.duckdb -c "SELECT * FROM aie_region_families('1',1,3000000);"
duckdb work/input.duckdb -c "SELECT * FROM aie_junction_labels('1',donor,acceptor);"
./check_evidence.sh
```

`donor` is the last aligned base before a skip; `acceptor` is the last skipped base. Choose observed junction coordinates for the query. An explicit `UB` preparation selects corrected tags. Missing selected tags are audited, not replaced by another tag. Source observations include alternative placements; default counts use primary mapped nonsupplementary evidence.

`DUCKDB`, `DUCKHTS_EXTENSION` and `LD_LIBRARY_PATH` select the reader runtime. Use a new output cache. Product tests use an independent scalar CIGAR cursor and pairwise interval graph under both tag policies; four semantic mutants must disagree with those oracles and restored SQL must pass.

## Gravlax compatibility surface

Gravlax is pinned at `75b8d6c01064ba92af295543d50230429774e170` and reports AIE 0.2.3. From this directory:

```sh
eval "$(./setup.sh)"
./test.sh
./mutation_test.sh
```

These tests regenerate synthetic BAMs, indexes, archives and Parquet relations. They compare region, junction, jset, annotation replay and signed annotation deltas exactly for both samples and annotation versions. All nine declared compatibility mutants must fail with explicit count differences; parser, setup and runtime errors do not count as semantic kills.

The [compatibility report](REPORT.md), [fixture rules](fixture/README.md) and [schema](SCHEMA.md) delimit this shared surface. Fixture tags make CR/CB and UR/UB equal; the [real pilot](evidence/real-pilot/README.md) exposes differences those fixtures cannot establish. Raw-UMI product policy is independently validated, not a promise of exhaustive upstream equivalence. Annotation replay remains the scoped compatibility implementation, not the independently specified product default.

Requirements: DuckDB/DuckHTS, samtools and R; the compatibility setup additionally needs Git/network access, Rust/Cargo, jq, curl and unzip. Generated inputs, dependencies and serving states are ignored. Committed evidence includes source snapshots, hashes and receipts; rendering reports does not rerun benchmark engines.
