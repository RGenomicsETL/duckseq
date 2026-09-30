LOAD 'ext/duckhts.duckdb_extension';

WITH RECURSIVE annotations AS (
  SELECT 'v1'::VARCHAR AS annotation, seqname AS contig,
         regexp_extract(attributes, 'gene_id "([^"]+)"', 1) AS gene_id,
         regexp_extract(attributes, 'transcript_id "([^"]+)"', 1) AS transcript_id,
         strand, start::BIGINT - 1 AS exon_start, "end"::BIGINT AS exon_end
  FROM read_gtf('fixture/annotation-v1.gtf') WHERE feature='exon'
  UNION ALL
  SELECT 'v2', seqname,
         regexp_extract(attributes, 'gene_id "([^"]+)"', 1),
         regexp_extract(attributes, 'transcript_id "([^"]+)"', 1),
         strand, start::BIGINT - 1, "end"::BIGINT
  FROM read_gtf('fixture/annotation-v2.gtf') WHERE feature='exon'
), transcript_exons AS (
  SELECT *, row_number() OVER (
    PARTITION BY annotation, contig, gene_id, transcript_id, strand
    ORDER BY exon_start, exon_end
  ) AS exon_order,
  count(*) OVER (
    PARTITION BY annotation, contig, gene_id, transcript_id, strand
  ) AS exon_count,
  min(exon_start) OVER (
    PARTITION BY annotation, contig, gene_id, transcript_id, strand
  ) AS transcript_start,
  max(exon_end) OVER (
    PARTITION BY annotation, contig, gene_id, transcript_id, strand
  ) AS transcript_end
  FROM annotations
), transcript_junctions AS (
  SELECT annotation, contig, gene_id, transcript_id, strand,
         exon_end AS donor, lead(exon_start) OVER (
           PARTITION BY annotation, contig, gene_id, transcript_id, strand
           ORDER BY exon_order
         ) AS acceptor
  FROM transcript_exons
), read_span AS (
  SELECT a.sample_id, a.read_id, a.flag, a.contig, a.pos_1based,
         sum(CASE WHEN right(t.token, 1) IN ('M','D','N','=','X')
                  THEN try_cast(left(t.token, length(t.token)-1) AS BIGINT) ELSE 0 END) AS span
  FROM read_parquet('work/alignments.parquet') a
  CROSS JOIN LATERAL unnest(regexp_extract_all(a.cigar, '[0-9]+[MIDNSHP=X]')) AS t(token)
  GROUP BY a.sample_id, a.read_id, a.flag, a.contig, a.pos_1based
), eligible_reads AS (
  SELECT a.*, g.blocks, g.operation_codes, list_sum(g.blocks.width) AS aligned_length,
         a.pos_1based - 1 AS alignment_start,
         a.pos_1based - 1 + s.span AS alignment_end
  FROM read_parquet('work/alignments.parquet') a
  JOIN read_parquet('work/read_geometry.parquet') g
    USING(sample_id, read_id, flag, contig, pos_1based, cigar)
  JOIN read_span s USING(sample_id, read_id, flag, contig, pos_1based)
  WHERE (a.flag & 4)=0 AND (a.flag & 256)=0 AND (a.flag & 2048)=0
), read_starts AS (
  SELECT *, lag(alignment_start) OVER (
    PARTITION BY sample_id, cell_barcode, contig, is_reverse
    ORDER BY alignment_start, read_id, flag
  ) AS previous_start
  FROM eligible_reads
), loci AS (
  SELECT *, sum(CASE WHEN previous_start IS NULL OR alignment_start-previous_start>50000
                     THEN 1 ELSE 0 END) OVER (
    PARTITION BY sample_id, cell_barcode, contig, is_reverse
    ORDER BY alignment_start, read_id, flag ROWS UNBOUNDED PRECEDING
  ) AS locus_id
  FROM read_starts
), umi_labels AS (
  SELECT l.*,
         coalesce((
           SELECT min(o.umi) FROM loci o
           WHERE o.sample_id=l.sample_id AND o.cell_barcode=l.cell_barcode
             AND o.contig=l.contig AND o.is_reverse=l.is_reverse AND o.locus_id=l.locus_id
             AND o.umi<l.umi
             AND (SELECT count(*) FROM unnest(generate_series(1,length(l.umi))) AS p(i)
                  WHERE substr(l.umi,p.i,1)<>substr(o.umi,p.i,1))=1
         ), l.umi) AS collapsed_umi
  FROM loci l
), umi_reads AS (
  SELECT *, row_number() OVER (
    PARTITION BY sample_id, cell_barcode, contig, is_reverse, locus_id, collapsed_umi
    ORDER BY aligned_length, read_id, flag
  ) AS representative_rank
  FROM umi_labels
), molecules AS (
  SELECT * EXCLUDE (representative_rank)
  FROM umi_reads WHERE representative_rank=1
), cigar_tokens AS (
  SELECT a.sample_id, a.read_id, a.flag, a.contig, a.pos_1based,
         t.i AS token_id, t.token,
         try_cast(left(t.token, length(t.token)-1) AS BIGINT) AS op_length,
         right(t.token, 1) AS op
  FROM read_parquet('work/alignments.parquet') a
  CROSS JOIN LATERAL unnest(regexp_extract_all(a.cigar, '[0-9]+[MIDNSHP=X]'))
       WITH ORDINALITY AS t(token, i)
  WHERE (a.flag & 4)=0 AND (a.flag & 256)=0 AND (a.flag & 2048)=0
), token_positions AS (
  SELECT t.*,
         count(*) FILTER (WHERE op='N') OVER (
           PARTITION BY sample_id,read_id,flag ORDER BY token_id ROWS UNBOUNDED PRECEDING
         ) AS block_id,
         coalesce(sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)
           OVER (PARTITION BY sample_id,read_id,flag ORDER BY token_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS ref_before
  FROM cigar_tokens t
), molecule_blocks AS (
  SELECT m.sample_id, m.cell_barcode AS cell_id, m.contig, m.is_reverse,
         m.read_id, m.flag, m.nh, m.alignment_start, m.alignment_end,
         p.block_id,
         min(m.pos_1based - 1 + p.ref_before) AS block_start,
         max(m.pos_1based - 1 + p.ref_before + p.op_length) AS block_end
  FROM molecules m JOIN token_positions p
    USING(sample_id, read_id, flag, contig, pos_1based)
  WHERE p.op IN ('M','D','=','X')
  GROUP BY m.sample_id,m.cell_barcode,m.contig,m.is_reverse,m.read_id,m.flag,m.nh,
           m.alignment_start,m.alignment_end,p.block_id
), molecule_junctions AS (
  SELECT m.sample_id, m.read_id, m.flag, m.contig, m.pos_1based,
         t.token_id AS junction_id,
         m.pos_1based - 1 + t.ref_before AS donor,
         m.pos_1based - 1 + t.ref_before + t.op_length AS acceptor
  FROM molecules m JOIN token_positions t
    USING(sample_id, read_id, flag, contig, pos_1based)
  WHERE t.op='N'
), transcript_candidates AS (
  SELECT e.annotation, b.sample_id, b.cell_id, e.gene_id, b.read_id, b.flag
  FROM molecule_blocks b
  JOIN transcript_exons e ON e.contig=b.contig
    AND ((b.is_reverse AND e.strand='-') OR (NOT b.is_reverse AND e.strand='+'))
    AND b.alignment_start >= e.transcript_start
    AND b.alignment_end <= e.transcript_end
  LEFT JOIN transcript_junctions tj
    ON tj.annotation=e.annotation AND tj.contig=e.contig
   AND tj.gene_id=e.gene_id AND tj.transcript_id=e.transcript_id AND tj.strand=e.strand
   AND tj.acceptor IS NOT NULL
  LEFT JOIN molecule_junctions j
    ON j.sample_id=b.sample_id AND j.read_id=b.read_id AND j.flag=b.flag
   AND j.contig=b.contig AND j.donor=tj.donor AND j.acceptor=tj.acceptor
  WHERE b.block_start >= e.exon_start AND b.block_end <= e.exon_end
  GROUP BY e.annotation, b.sample_id, b.cell_id, e.gene_id, b.read_id, b.flag,
           e.transcript_id, e.contig, e.strand, e.exon_count
  HAVING count(DISTINCT b.block_id) = (
           SELECT count(DISTINCT mb.block_id) FROM molecule_blocks mb
           WHERE mb.sample_id=b.sample_id AND mb.read_id=b.read_id AND mb.flag=b.flag
         )
     AND count(DISTINCT j.junction_id) = (
           SELECT count(*) FROM molecule_junctions mj
           WHERE mj.sample_id=b.sample_id AND mj.read_id=b.read_id AND mj.flag=b.flag
         )
), unique_assignments AS (
  SELECT tc.annotation, tc.sample_id, tc.cell_id, tc.gene_id, tc.read_id, tc.flag
  FROM transcript_candidates tc
  GROUP BY tc.annotation, tc.sample_id, tc.cell_id, tc.gene_id, tc.read_id, tc.flag
  QUALIFY count(DISTINCT tc.gene_id) OVER (
    PARTITION BY tc.annotation, tc.sample_id, tc.cell_id, tc.read_id, tc.flag
  )=1
), counts AS (
  SELECT annotation, sample_id, cell_id, gene_id, count(*) AS molecules
  FROM unique_assignments
  GROUP BY annotation, sample_id, cell_id, gene_id
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
