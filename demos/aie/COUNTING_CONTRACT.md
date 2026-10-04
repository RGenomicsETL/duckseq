# Counting contract

## Product and compatibility surfaces

The product preserves inspectable alignment evidence and supports composable region, junction and annotation queries. Gravlax is a comparator for shared capabilities, not the definition of every counting policy. The fixture's existing compatibility queries remain a separately scoped surface.

The source BAM is authoritative. Derived serving tables record the input, reader/runtime identity, selected tag policy and rebuild command. Raw CR/UR and supplied corrected CB/UB remain distinct; source observations and alternative placements are retained.

## Default evidence policy

- Trust a nonempty supplied **CB** as the cell assignment, including its GEM-group suffix. Do not recorrect it using a different whitelist.
- Use **raw UR** for the default evidence view. Preserve supplied UB and offer an explicit corrected-tag view. UB may contain annotation-dependent correction and is not silently substituted when UR is absent.
- Mapped primary, nonsupplementary records with the selected tags participate in counts. Retain other records for auditing. Multimapping uncertainty is not converted into a unique assignment merely because a primary placement exists.
- Treat exact UMI strings, including their length, as labels. Apply no implicit Hamming-neighbor absorption or equal-abundance tie correction. These are exact-label counts, not error-corrected physical-molecule estimates.
- M, D, N, = and X advance the reference cursor. Only N creates a splice junction. Region support follows the reference span; this includes internal deletions/skips and is distinct from exonic coverage.

## Public count meanings

1. **UMI labels:** distinct selected UMI strings per cell and requested interval/junction. A reused UMI in separate genomic contexts is still one label; this result must not be named a physical-molecule count.
2. **Evidence families:** same cell, selected UMI, contig and strand, with overlapping primary reference spans joined transitively. No arbitrary 50 kb gap rule and no sequence-error correction. A family may split evidence from one biological molecule or merge collisions; retain its source observations so annotation replay can resolve them.
3. **Annotation-specific exact UMIs:** assign read evidence under an explicit feature/strand/ambiguity policy, then deduplicate by cell, assigned feature and raw UMI. Distinct genes sharing a UMI remain distinct. This surface does not inherit upstream abundance/tie rules without an explicitly selected correction model.

The serving-cache implementation covers the first two surfaces. Annotation-specific replay remains the demo's scoped compatibility implementation until the independent assignment/correction policy has its own tests; it is not advertised as the new default.

Missing CB or selected UMI makes an observation unavailable for that view, not a measured biological zero. Audit counts report excluded observations and raw/corrected tag disagreements.

## Validation and comparison

Scalar oracles and mutation tests validate coordinates, family membership, missing-tag handling, strand separation and count definitions. Shared-policy fixtures may compare exactly with Gravlax. A real-input disagreement is examined and classified, not automatically accepted as a bug or excused as intentional.

Performance comparisons state the count meaning and returned representation. Differing counts/policies can support a capability/cost contrast, not an equal-output speedup. Preparation includes materialization; repeated queries use the prepared geometry consistently for both products.
