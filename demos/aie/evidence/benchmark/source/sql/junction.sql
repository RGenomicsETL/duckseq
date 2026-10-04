WITH ops AS (
  SELECT sample_id, alignment_id, read_id, flag, contig, pos_1based, operation_order,
         CAST(left(operation_token, length(operation_token) - 1) AS BIGINT) AS op_length,
         right(operation_token, 1) AS op
  FROM read_parquet('work/cigar_operations.parquet')
), positioned AS (
  SELECT *, pos_1based - 1 + coalesce(sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)
    OVER (PARTITION BY sample_id, alignment_id ORDER BY operation_order ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS ref_before
  FROM ops
), support AS (
  SELECT a.sample_id, a.cell_barcode AS cell_id, a.umi AS umi_id
  FROM positioned p JOIN read_parquet('work/alignments.parquet') a USING(sample_id, alignment_id)
  WHERE p.op = 'N' AND p.contig = 'chr1' AND p.ref_before = 14 AND p.op_length = 10
  GROUP BY a.sample_id, cell_id, umi_id
)
SELECT sample_id, cell_id, count(*) AS umi_count
FROM support GROUP BY sample_id, cell_id ORDER BY sample_id, cell_id;
