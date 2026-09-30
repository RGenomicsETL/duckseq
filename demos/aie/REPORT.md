# Fourth-pass replay parity report

## Discriminating fixture

`fixture/README.md` records the source-derived expected result for each added read group. SAM records are emitted with `printf` tab escapes and checked as 18 tab-separated fields before samtools runs. The chain and tie UMIs occupy separate strands/loci so their abundance counts do not contaminate each other. Both `.aie` archives are rebuilt by `./test.sh` from the updated BAM fixtures.

## Failure after fixture expansion, before SQL corrections

```text
PASS region and junction counts match Gravlax for both samples
jset include-only mismatch: SQL=3 AIE=2
```

This was a real exact-comparison failure. The fixture exposed that the old SQL treated the two positive junction memberships as separate include-only classes and did not recognize the read supporting both predicates as `both`.

## Passing output after SQL corrections

```text
[E::idx_find_and_load] Could not retrieve index file for 'fixture/annotation-v1.gtf'
[E::idx_find_and_load] Could not retrieve index file for 'fixture/annotation-v2.gtf'
[E::idx_find_and_load] Could not retrieve index file for 'fixture/annotation-v1.gtf'
[E::idx_find_and_load] Could not retrieve index file for 'fixture/annotation-v2.gtf'
PASS region and junction counts match Gravlax for both samples
AIE compare-annotations signed deltas sample_a: [[0,"AAAAAAAAAAAAAAAA","geneA","geneA","geneA",1,0,-1]]
AIE compare-annotations signed deltas sample_b: [[0,"CCCCCCCCCCCCCCCC","geneA","geneA","geneA",1,0,-1]]
PASS region, junction, jset, and annotation counts match Gravlax for both samples
```

The `idx_find_and_load` messages concern optional GTF indexes; they are non-fatal. The signed deltas are the expected v1-to-v2 annotation changes, and the test compares those exactly.

## Implemented rules and source

- **UMI collapse:** SQL counts primary read observations per cell/strand/locus/UMI, picks a parent only among Hamming-distance-one UMIs with strictly greater abundance, orders candidates by abundance descending then UMI ascending, and recursively resolves each parent chain to its root (`sql/annotation_counts.sql`; Gravlax `crates/aie/src/build.rs:240–257, 274–324`). For the fixture's fixed-length ACGT UMIs, lexical A<C<G<T order is identical to the source's packed 2-bit A=0,C=1,G=2,T=3 order (`crates/evidence-io/src/umi.rs:1–20`). This produces X←Y while leaving Z uncollapsed, and resolves the equal-count P/Q/R case by choosing P without collapsing P into Q.
- **Multimappers:** `molecule_placements` carries the selected corrected molecule's retained primary read observations into `cigar_tokens`; token expansion keeps secondary records and computes each placement's own blocks and junctions. Candidate genes are unioned across placements before `unique_assignments` accepts a molecule only if that union contains one gene (`sql/annotation_counts.sql`; Gravlax replay `crates/aie/src/rows.rs:3288–3330`). Thus cross-gene alternatives are ambiguous, while alternatives confined to geneB still yield geneB.
- **Jset `both`:** SQL advances the reference cursor over prior `N` operations, records include/exclude junction evidence per cell/UMI class, and sets `both` only when that same class supports each predicate (`sql/jset.sql`; Gravlax jset class categories in `crates/aie/src/querycmd.rs:2309–2345`).
- **Recursive SQL:** `WITH RECURSIVE` remains necessary for `umi_resolution`; it follows the greedily selected parent links to their terminal UMI roots.

## Remaining scope and limits

The fixture uses 12-base ACGT UMIs. Gravlax's packed UMI key compares numeric `u32` values, while SQL orders the text UMIs; those orderings are identical for the fixed-length UMIs exercised here, but differing UMI lengths with leading A bases have not been tested for tie-order parity. The pass establishes exact results for this fixture and both annotation versions; it is not a claim of exhaustive parity over all Gravlax input modes.
