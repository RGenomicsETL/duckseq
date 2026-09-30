# Relational schema

All coordinates in `alignments.parquet` and `read_geometry.parquet` preserve the BAM's 1-based POS convention. CIGAR block starts returned by DuckHTS use the supplied POS and retain that convention. Junction boundaries are separately derived as 0-based interbase coordinates. Tables are written in deterministic key order; Parquet does not promise physical row order to readers.

| Relation | Key | Sort key | Meaning |
|---|---|---|---|
| `sample_archive.parquet` | `(sample_id, archive_id)` | sample, archive | Sample/archive identity, fixture assembly, input coordinate convention. |
| `reference_dictionary.parquet` | `(sample_id, contig)` | sample, contig | Assembly, contig length, strand/coordinate interpretation. |
| `alignments.parquet` | `(sample_id, read_id, flag, contig, pos_1based)` | sample, contig, POS, read, flag | One retained BAM record, typed SAM fields and CB/UB/CR/UR/NH/HI tags. |
| `cigar_operations.parquet` | `(sample_id, read_id, flag, operation_order)` | sample, contig, POS, read, flag | Ordered, typed source CIGAR tokens. Operation letters keep D distinct from N. |
| `read_geometry.parquet` | `(sample_id, read_id, flag)` | sample, contig, POS, read, flag | DuckHTS aligned blocks and ordered operation-code list; D and N may yield equivalent blocks but remain distinguishable in the op list. |
| `placement_alternatives.parquet` | `(sample_id, read_id, placement_ordinal)` | sample, read, ordinal | Placement multiplicity and equal share `1/NH`; alternatives do not create molecule rows. BAM-observed records only. |
| `cell_umi_membership.parquet` | `(sample_id, read_id, flag)` | sample, read, flag | Raw/current barcode and UMI membership. No correction, mismatch collapse, or multi-gene policy is applied. |
| `capabilities.parquet` | `capability` | capability | Explicit available, partially available, and unavailable facts; a missing observation is not a measured zero. |

## Scope and limitations

The fixture uses two separately identified samples and archive files. `NH` placement weights here are descriptive equal weights; Gravlax's normal count queries count a molecule class, not one record per alternative. An unobserved alignment, sequence absent from the BAM, corrected-away barcode, and biological zero are not inferable from these relations. Raw nucleotide UMIs remain values in this SQL exercise, unlike Gravlax's production archive quotient representation.
