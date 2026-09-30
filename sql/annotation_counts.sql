WITH exons AS (
  SELECT 'v1'::VARCHAR AS annotation, column0 AS contig,
         CAST(column3 AS BIGINT) AS exon_start, CAST(column4 AS BIGINT) AS exon_end,
         regexp_extract(column8, 'gene_id "([^"]+)"', 1) AS gene_id
  FROM read_csv('fixture/annotation-v1.gtf', delim='\t', header=false, columns={'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR','column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR','column6':'VARCHAR','column7':'VARCHAR','column8':'VARCHAR'})
  UNION ALL
  SELECT 'v2', column0, CAST(column3 AS BIGINT), CAST(column4 AS BIGINT),
         regexp_extract(column8, 'gene_id "([^"]+)"', 1)
  FROM read_csv('fixture/annotation-v2.gtf', delim='\t', header=false, columns={'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR','column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR','column6':'VARCHAR','column7':'VARCHAR','column8':'VARCHAR'})
), unique_blocks AS (
  SELECT a.sample_id, a.cell_barcode AS cell_id, a.umi AS umi_id,
         a.contig, unnest(g.blocks.ref_start) AS block_start,
         unnest(g.blocks.width) AS block_width
  FROM read_parquet('work/alignments.parquet') a
  JOIN read_parquet('work/read_geometry.parquet') g
    USING(sample_id, read_id, flag, contig, pos_1based, cigar)
  WHERE coalesce(a.nh, 1)=1 AND (a.flag & 4)=0
), assignments AS (
  SELECT e.annotation, b.sample_id, b.cell_id, b.umi_id, e.gene_id
  FROM unique_blocks b JOIN exons e
    ON b.contig=e.contig
   AND b.block_start <= e.exon_end
   AND b.block_start + b.block_width - 1 >= e.exon_start
  GROUP BY e.annotation, b.sample_id, b.cell_id, b.umi_id, e.gene_id
), counts AS (
  SELECT annotation, sample_id, cell_id, gene_id, count(DISTINCT umi_id) AS molecules
  FROM assignments GROUP BY annotation, sample_id, cell_id, gene_id
)
SELECT coalesce(a.sample_id, b.sample_id) AS sample_id,
       coalesce(a.cell_id, b.cell_id) AS cell_id,
       coalesce(a.gene_id, b.gene_id) AS gene_id,
       coalesce(a.molecules, 0) AS v1_count,
       coalesce(b.molecules, 0) AS v2_count,
       coalesce(b.molecules, 0) - coalesce(a.molecules, 0) AS signed_delta_v2_minus_v1
FROM (SELECT * FROM counts WHERE annotation='v1') a
FULL OUTER JOIN (SELECT * FROM counts WHERE annotation='v2') b
  USING(sample_id, cell_id, gene_id)
WHERE coalesce(a.molecules, 0) <> 0 OR coalesce(b.molecules, 0) <> 0
ORDER BY sample_id, cell_id, gene_id;
