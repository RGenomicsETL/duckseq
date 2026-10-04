WITH operations AS (
  SELECT sample_id, alignment_id,
         unnest(regexp_extract_all(cigar, '[0-9]+[MDN=X]')) AS token
  FROM read_parquet('work/alignments.parquet')
), reference_spans AS (
  SELECT sample_id, alignment_id,
         sum(CAST(left(token, length(token)-1) AS BIGINT)) AS span
  FROM operations GROUP BY sample_id, alignment_id
)
SELECT a.sample_id, a.cell_barcode AS cell_id,
       count(DISTINCT a.umi) AS umi_count
FROM read_parquet('work/alignments.parquet') a
JOIN reference_spans s USING(sample_id, alignment_id)
WHERE a.contig='chr1'
  AND a.pos_1based <= 100
  AND a.pos_1based + s.span - 1 >= 1
GROUP BY a.sample_id, cell_id
ORDER BY a.sample_id, cell_id;
