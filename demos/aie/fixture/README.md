# Replay fixture

`build.sh` creates a 120-base reference, two cell barcodes, paired BAMs, and two GTF versions. Every comparison read used for annotation replay overlaps an exon in both versions. The archive is rebuilt with geometry fidelity for each test run.

| Reads | Discriminating observation | Gravlax rule |
|---|---|---|
| `*_splice`, `*_splice_rep` | The two splice reads form the ordinary one-substitution UMI pair in geneA. | `crates/ingest/src/cigar.rs:58-63` records a junction for `Skip`; `:51-57` extends a block for `Del`. |
| `*_deletion` | The deletion read aligns wholly inside geneD; treating its `D` as a junction rejects its assignment. | `crates/ingest/src/cigar.rs:51-63` explicitly extends the block for `Del` and creates junction evidence only for `Skip`. |
| `*_chain_x*`, `*_chain_y`, `*_chain_z*` | Reverse-strand geneE reads form an X/Y/Z chain with abundances 3/1/2. Abundance-first ranking leaves X and Z as roots; lexical-only ranking joins all three. | `crates/aie/src/rows.rs:4582-4614` ranks by abundance and class ID and merges only toward an earlier adjacent class. |
| `*_tie_TTT*`, `*_tie_CTT*`, `*_tie_r` | These equal-abundance reads overlap geneF and provide a tie-parent choice. | `crates/aie/src/rows.rs:4582-4614` ranks classes by abundance and class ID, merges a class only toward an earlier adjacent class, and increments the output count only for roots. |
| `*_tieorder_*` | Equal-abundance geneF UMIs include a three-node branch (`AAG`, `ACG`, `CAG` prefixes) and a square (`GG`, `GT`, `TG`, `TT`). The branch has one root in ascending order and two in descending order; the square tests transitive absorption. | `crates/aie/src/rows.rs:4582-4614` specifies the rank and earlier-neighbor rule; `:4613-4627` returns root counts per cell and gene. |
| `*_multi_cross` | The 5M secondary placement lies in geneA while the primary lies in geneB. The alternative's gene must join the candidate set, making the molecule ambiguous. | `crates/aie/src/rows.rs:3288-3325` evaluates each pattern alternative; replay passes `MmMissing::SkipAlt` at `:4399-4406`. |
| `*_multi_same` | Both placements overlap geneB; the NH=2 molecule still has one gene candidate and is assigned. | `crates/aie/src/rows.rs:3288-3325` unions genes across alternatives, while replay accepts a singleton at `:4411-4418`. The NH=2 same-gene alternative is retained. The `NH == 1` condition in `crates/anno/src/assign.rs:319-322` is policy for STARsolo concordant assignment, not the replay path. |
| `*_both` | One molecule has junctions `chr1:14-24` and `chr1:29-39`, satisfying include and exclude simultaneously. | `crates/ingest/src/cigar.rs:58-63` represents `N` operations as junctions. |
| `*_laterjunction` | `5M5N5M10N5M` at POS 5 has junctions 9–14 and 19–29, not 14–24. | `crates/ingest/src/cigar.rs:58-63` advances the reference cursor across each skip. |
| `*_three` | One primary and two secondaries share the read ID; both secondaries have flag 256 and separate coordinates. | Placement geometries must remain separate before candidate-gene assignment. |

Mutation outcomes are checked with both sample barcodes; the read names below identify the same discriminating geometries in each sample.

| Mutant | Killing reads and expected Gravlax result |
|---|---|
| (a) Strict-abundance parents only | `*_tieorder_*` distinguishes equal-abundance earlier-parent absorption. Replay ranks equal-abundance classes by packed value and permits an earlier adjacent class as parent (`crates/aie/src/rows.rs:4582-4614`). |
| (b) Lexical neighbor without abundance | The 3/1/2 chain `*_chain_x*`, `*_chain_y`, `*_chain_z*` retains two geneE roots under abundance-first ranking, versus one under lexical-only ranking (`crates/aie/src/rows.rs:4582-4614`). |
| (c) Exact UMIs only | `*_splice`, `*_splice_rep`, and the one-mismatch chain/tie UMIs. Expected: the recorded corrected-root counts under the abundance-first earlier-neighbor rule at `crates/aie/src/rows.rs:4586-4614`. |
| (d) Reverse packed-value tie order | The equal-abundance `AAG`/`ACG`/`CAG` branch in `*_tieorder_*` changes from one root to two. Expected order is the class-ID tie break in `crates/aie/src/rows.rs:4588-4609`. |
| (e) Drop secondary before gene assignment | `*_multi_cross`. Its secondary 5M placement overlaps geneA while the primary overlaps geneB. Expected: alternatives are both considered and the two-gene result is excluded by singleton assignment (`crates/aie/src/rows.rs:3288-3325`, `:4411-4418`). |
| (f) Require `NH == 1` | `*_multi_same` has NH=2 placements with a singleton geneB candidate and must contribute. Filtering NH=2 removes that contribution. Replay's alternative collection and singleton policy are at `crates/aie/src/rows.rs:3288-3325` and `:4397-4418`; the `NH == 1` policy at `crates/anno/src/assign.rs:319-322` belongs to STARsolo concordant assignment. |
| (g) Treat deletion as junction | `*_deletion`. Expected: the read remains within geneD because `Del` extends its block, while only `Skip` produces a junction (`crates/ingest/src/cigar.rs:51-63`). |
| (h) Omit preceding N from the reference cursor | `*_laterjunction` must support 19–29 and must not add support to 14–24. |
| (i) Group placements by read name and flag | `*_three` requires distinct secondary geometry before singleton-gene assignment; combining its secondaries changes annotation counts. |

Annotation v1 assigns exon 25-29 to geneA; v2 assigns it to geneC. Both retain geneB at 30-39, geneD at 40-59, reverse-strand geneE at 70-79, and geneF at 90-99. The primary and secondary placement records share a read ID; replay evaluates the alternatives before deciding whether the read has exactly one candidate gene.
