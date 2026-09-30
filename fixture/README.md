# Replay fixture

`build.sh` creates a 120-base reference, two cell barcodes, paired BAMs, and two GTF versions. Every comparison read used for annotation replay overlaps an exon in both versions. The archive is rebuilt with geometry fidelity for each test run.

| Reads | Discriminating observation | Gravlax rule |
|---|---|---|
| `*_splice`, `*_splice_rep` | The two splice reads form the ordinary one-substitution UMI pair in geneA. | `crates/ingest/src/cigar.rs:58-63` records a junction for `Skip`; `:51-57` extends a block for `Del`. |
| `*_deletion` | The deletion read aligns wholly inside geneD; treating its `D` as a junction rejects its assignment. | `crates/ingest/src/cigar.rs:51-63` explicitly extends the block for `Del` and creates junction evidence only for `Skip`. |
| `*_chain_x*`, `*_chain_y`, `*_chain_z` | These reverse-strand reads overlap geneE. The X/Y/Z abundance chain separates abundance-directed correction from a lexicographically selected neighbor. | `crates/aie/src/build.rs:238-256` sorts by descending abundance then packed UMI and absorbs only a strictly more abundant one-mismatch neighbor. |
| `*_tie_A*`, `*_tie_C*`, `*_tie_r` | These equal-abundance reads overlap geneF and provide a tie-parent choice. | `crates/aie/src/rows.rs:4582-4614` ranks classes by abundance and class ID, merges a class only toward an earlier adjacent class, and increments the output count only for roots. |
| `*_tieorder_*` | The equal-abundance UMI square (`GG`, `GT`, `TG`, `TT` prefixes) overlaps geneF. Gravlax's packed-value order yields one root; reversing that order yields two. | `crates/aie/src/rows.rs:4582-4614` specifies the rank and earlier-neighbor rule; `:4613-4627` returns root counts per cell and gene. |
| `*_multi_cross` | The 5M secondary placement lies in geneA while the primary lies in geneB. The alternative's gene must join the candidate set, making the molecule ambiguous. | `crates/aie/src/rows.rs:3288-3325` evaluates each pattern alternative; replay passes `MmMissing::SkipAlt` at `:4399-4406`. |
| `*_multi_same` | Both placements overlap geneB; the NH=2 molecule still has one gene candidate and is assigned. | `crates/aie/src/rows.rs:3288-3325` unions genes across alternatives, while replay accepts a singleton at `:4411-4418`. The NH=2 same-gene alternative is retained. The `NH == 1` condition in `crates/anno/src/assign.rs:319-322` is policy for STARsolo concordant assignment, not the replay path. |
| `*_both` | One molecule has junctions `chr1:14-24` and `chr1:29-39`, satisfying include and exclude simultaneously. | `crates/ingest/src/cigar.rs:58-63` represents `N` operations as junctions. |

Mutation outcomes are checked with both sample barcodes; the read names below identify the same discriminating geometries in each sample.

| Mutant | Killing reads and expected Gravlax result |
|---|---|
| (a) Historical `6c25368` SQL | `*_chain_x*`, `*_chain_y`, `*_chain_z`, `*_tieorder_*`, `*_multi_cross`, and `*_deletion`. Their loci distinguish abundance/tie collapse, alternative-gene assignment, and D-versus-N handling. Expected: one geneE UMI root, one geneF square root, no gene assignment for the cross-gene alternative, and geneD assignment for the deletion. See `crates/aie/src/rows.rs:4582-4614`, `:3288-3325`, and `crates/ingest/src/cigar.rs:51-63`. |
| (b) Lexical neighbor without abundance | `*_chain_x*`, `*_chain_y`, `*_chain_z` and `*_tieorder_*` alter geneE/geneF root counts when selection ignores the abundance-first rank. Expected: classes follow the abundance and packed-value rank at `crates/aie/src/rows.rs:4582-4614`. |
| (c) Exact UMIs only | `*_splice`, `*_splice_rep`, and the one-mismatch chain/tie UMIs. Expected: one corrected root for each connected component under the earlier-neighbor rule at `crates/aie/src/rows.rs:4586-4614`. |
| (d) Reverse packed-value tie order | `*_chain_y`, `*_chain_z` and `*_tieorder_*`. Reversing order changes which equally abundant classes have earlier adjacent neighbors, changing the geneE and geneF root counts. Expected order is the class-ID tie break in `crates/aie/src/rows.rs:4588-4609`. |
| (e) Drop secondary before gene assignment | `*_multi_cross`. Its secondary 5M placement overlaps geneA while the primary overlaps geneB. Expected: alternatives are both considered and the two-gene result is excluded by singleton assignment (`crates/aie/src/rows.rs:3288-3325`, `:4411-4418`). |
| (f) Require `NH == 1` | `*_multi_cross`. Removing NH=2 records also removes its geneA alternative, incorrectly leaving the geneB primary as a singleton. Replay's alternative collection and singleton policy are at `crates/aie/src/rows.rs:3288-3325` and `:4397-4418`; the `NH == 1` comment at `crates/anno/src/assign.rs:319-322` belongs to STARsolo concordant assignment. |
| (g) Treat deletion as junction | `*_deletion`. Expected: the read remains within geneD because `Del` extends its block, while only `Skip` produces a junction (`crates/ingest/src/cigar.rs:51-63`). |

Annotation v1 assigns exon 25-29 to geneA; v2 assigns it to geneC. Both retain geneB at 30-39, geneD at 40-59, reverse-strand geneE at 70-79, and geneF at 90-99. The primary and secondary placement records share a read ID; replay evaluates the alternatives before deciding whether the read has exactly one candidate gene.
