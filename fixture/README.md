# Hand-written fixture

`build.sh` writes the 100-base `chr1` reference, the two-barcode whitelist, two sample BAMs, and two GTF annotation versions. Every sample has the same reads in a different cell, allowing identical geometries to be compared across cells.

| Read name | Purpose |
|---|---|
| `*_splice` | `5M10N5M` splice at `chr1:14-24`, UMI `AAAAAAAAAAAA`. |
| `*_deletion` | `5M10D5M`, same aligned block coordinates as the splice, but no splice junction; UMI `CCCCCCCCCCCC`. |
| `*_splice_rep` | Repeats the splice geometry with a one-substitution UMI (`AAAAAAAAAAAC`). |
| `*_multi` primary/secondary | `NH:i:2`, `HI:i:1/2`; tests retained placement alternatives and prevents alternative expansion from doubling a molecule. |

Both BAM headers declare a separate sample/read group. `CB`/`UB` and raw `CR`/`UR` are present. The whitelist contains both cell barcodes. Annotation v1 places exons 10-14 and 25-29 in geneA; v2 changes the latter exon to geneC. Both retain geneB at 30-39.

The fixture intentionally does not claim a `jset` same-molecule-positive case: it tests include-only evidence against an absent exclusion junction. A two-junction same-molecule fixture is needed before interpreting positive `both` output.
