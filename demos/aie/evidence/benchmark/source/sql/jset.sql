-- A molecule class must contain evidence for both junction predicates; evidence
-- from two different cell/UMI memberships cannot satisfy this same-molecule test.
WITH ops AS (
  SELECT *, CAST(left(operation_token, length(operation_token)-1) AS BIGINT) AS op_length,
         right(operation_token,1) AS op
  FROM read_parquet('work/cigar_operations.parquet')
), positioned AS (
  SELECT *, pos_1based - 1 + coalesce(sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)
    OVER (PARTITION BY sample_id, alignment_id ORDER BY operation_order ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS ref_before
  FROM ops
), junctions AS (
  SELECT a.sample_id, a.cell_barcode AS cell_id, a.umi AS umi_id,
         p.contig, p.ref_before AS donor, p.ref_before + p.op_length AS acceptor
  FROM positioned p
  JOIN (
    SELECT sample_id, alignment_id, read_id, flag, cell_barcode, umi
    FROM read_parquet('work/alignments.parquet')
  ) a USING(sample_id, alignment_id)
  WHERE p.op='N'
), class_evidence AS (
  SELECT sample_id, cell_id, umi_id,
         bool_or(contig='chr1' AND donor=14 AND acceptor=24) AS includes_junction,
         bool_or(contig='chr1' AND donor=29 AND acceptor=39) AS excludes_junction
  FROM junctions GROUP BY sample_id, cell_id, umi_id
)
SELECT sample_id, cell_id, umi_id, includes_junction, excludes_junction,
       includes_junction AND excludes_junction AS same_molecule_supports_both
FROM class_evidence ORDER BY sample_id, cell_id, umi_id;

-- Separate classes are listed independently and never joined into a class-level
-- positive simply because one class supports each side.
