# Hand-written fixture

`build.sh` creates a 100-base `chr1` reference, two cell barcodes, two BAMs, and two GTF versions. Every sample contains the same read geometries in a different cell. SAM records generated with `printf` contain literal tab delimiters; the build checks every record has 21 tab-separated fields before calling samtools.

| Read group | Purpose and source-derived expected result |
|---|---|
| `*_splice`, `*_deletion`, `*_splice_rep` | Distinguishes `N` from `D` and supplies an ordinary one-substitution UMI pair. Gravlax retains splice junction evidence only for `N`. |
| `*_chain_x*`, `*_chain_y`, `*_chain_z` | One locus has X×3, Y×1, Z×1, with X-Y and Y-Z at Hamming distance one and X-Z at distance two. `build.rs:240–257` orders by descending abundance, ties by packed UMI, and absorbs only into a strictly more abundant earlier neighbour. Thus Y resolves to X, but Z remains Z: Y's own abundance is not strictly greater than Z's. |
| `*_tie_A*`, `*_tie_C*`, `*_tie_r` | P=`AAAAAAAAAAAA` and Q=`CCAAAAAAAAAA` each occur twice; R=`ACAAAAAAAAAA` occurs once and differs from each by one base. The equal-count pair cannot absorb one another, and the packed-value order puts P first, so R joins P (`build.rs:240–257`). |
| `*_multi_cross` | Primary placement is in geneB and secondary placement in geneA. Replay unions genes over alternatives, so the molecule has multiple gene candidates and is excluded from unique gene assignment (`rows.rs:3288–3330`). |
| `*_multi_same` | Both primary and secondary placements lie within geneB. Their gene union is still only geneB, so the molecule remains a single geneB candidate (`rows.rs:3288–3330`). |
| `*_both` | One molecule has junctions `chr1:14-24` and `chr1:29-39`, satisfying include and exclude simultaneously; Gravlax's `jset` must count it in `both`. |

Both BAM headers declare a separate sample/read group, and `CB`/`UB` plus raw `CR`/`UR` are present. Annotation v1 places exons 10-14, 25-29, and 40-44 in geneA; v2 assigns 25-29 to geneC while retaining the other fixture exons. Both retain geneB at 30-39. The original `*_multi` read also provides two observed placements; secondary records must remain available through gene assignment rather than being discarded before forming the placement group.
