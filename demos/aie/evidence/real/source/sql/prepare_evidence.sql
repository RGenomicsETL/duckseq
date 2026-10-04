-- Caller sets bam_path, sample_id and umi_tag (UR or UB); open a new DuckDB cache.
SELECT CASE WHEN getvariable('umi_tag') IN ('UR','UB') THEN true
            ELSE error('umi_tag must be UR or UB') END;
CREATE TABLE evidence_policy AS
SELECT getvariable('sample_id')::VARCHAR AS sample_id,
       getvariable('bam_path')::VARCHAR AS source_bam,
       getvariable('umi_tag')::VARCHAR AS umi_tag,
       'CB'::VARCHAR AS cell_tag,
       'exact labels; overlap-connected primary spans'::VARCHAR AS count_policy;
CREATE TABLE observations AS
SELECT row_number() OVER () AS alignment_id,
       QNAME AS read_id, FLAG::UINTEGER AS flag, RNAME AS contig,
       POS::BIGINT AS ref_start, CIGAR AS cigar, MAPQ AS mapq,
       NH AS nh, HI AS hi, CB AS cell_id, CR AS raw_cell_id,
       AUXILIARY_TAGS['UR']::VARCHAR AS raw_umi,
       AUXILIARY_TAGS['UB']::VARCHAR AS corrected_umi,
       AUXILIARY_TAGS[getvariable('umi_tag')]::VARCHAR AS umi,
       (FLAG & 16) != 0 AS reverse,
       (FLAG & 2308) = 0 AS primary_mapped
FROM read_bam(getvariable('bam_path'), standard_tags := TRUE, auxiliary_tags := TRUE)
ORDER BY contig,ref_start;
CREATE TEMP TABLE tokens AS
WITH lists AS (
  SELECT alignment_id,ref_start,regexp_extract_all(cigar,'[0-9]+[MIDNSHP=X]') AS ops
  FROM observations
), ordered AS (
  SELECT alignment_id,ref_start,generate_subscripts(ops,1) AS op_i,unnest(ops) AS token
  FROM lists
)
SELECT *,right(token,1) AS op,left(token,length(token)-1)::BIGINT AS op_length
FROM ordered;
CREATE TABLE geometry AS
SELECT alignment_id,min(ref_start) AS ref_start,
       min(ref_start)+sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)-1 AS ref_end
FROM tokens GROUP BY alignment_id
HAVING sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)>0;
CREATE TABLE junctions AS
WITH positioned AS (
  SELECT *,ref_start-1+coalesce(sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)
    OVER (PARTITION BY alignment_id ORDER BY op_i ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS donor
  FROM tokens
)
SELECT alignment_id,donor,donor+op_length AS acceptor FROM positioned WHERE op='N';
DROP TABLE tokens;
CREATE TABLE counting_reads AS
SELECT o.alignment_id,o.read_id,o.cell_id,o.umi,o.contig,o.reverse,o.ref_start,g.ref_end,o.nh
FROM observations o JOIN geometry g USING(alignment_id)
WHERE primary_mapped AND cell_id IS NOT NULL AND cell_id<>'' AND umi IS NOT NULL AND umi<>''
ORDER BY o.contig,o.ref_start;
CREATE TABLE family_members AS
WITH previous AS (
  SELECT alignment_id,cell_id,umi,contig,reverse,ref_start,ref_end,
         max(ref_end) OVER (PARTITION BY cell_id,umi,contig,reverse
           ORDER BY ref_start,ref_end,alignment_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_end
  FROM counting_reads
), runs AS (
  SELECT *,sum(CASE WHEN prior_end IS NULL OR ref_start>prior_end THEN 1 ELSE 0 END)
    OVER (PARTITION BY cell_id,umi,contig,reverse ORDER BY ref_start,ref_end,alignment_id) AS ordinal
  FROM previous
)
SELECT alignment_id,dense_rank() OVER (ORDER BY cell_id,umi,contig,reverse,ordinal) AS family_id
FROM runs;
CREATE TABLE families AS
SELECT m.family_id,o.cell_id,o.umi,o.contig,o.reverse,
       min(o.ref_start) AS ref_start,max(o.ref_end) AS ref_end,count(*) AS alignment_count
FROM family_members m JOIN counting_reads o USING(alignment_id)
GROUP BY m.family_id,o.cell_id,o.umi,o.contig,o.reverse
ORDER BY contig,ref_start;
CREATE TABLE family_junctions AS
SELECT DISTINCT m.family_id,o.contig,j.donor,j.acceptor
FROM family_members m JOIN counting_reads o USING(alignment_id) JOIN junctions j USING(alignment_id)
ORDER BY contig,donor,acceptor;
CREATE TABLE evidence_audit AS
SELECT count(*) AS source_records,
       count(*) FILTER (WHERE NOT primary_mapped) AS nonprimary_or_unmapped,
       count(*) FILTER (WHERE primary_mapped AND (cell_id IS NULL OR cell_id='')) AS missing_cell,
       count(*) FILTER (WHERE primary_mapped AND (umi IS NULL OR umi='')) AS missing_selected_umi,
       count(*) FILTER (WHERE primary_mapped AND nh>1) AS ambiguous_primary_placements,
       count(*) FILTER (WHERE raw_umi<>corrected_umi) AS raw_corrected_umi_disagreements
FROM observations;
CREATE MACRO aie_region_labels(chr,lo,hi) AS TABLE
SELECT p.sample_id,o.cell_id,count(DISTINCT o.umi) AS umi_label_count
FROM counting_reads o CROSS JOIN evidence_policy p
WHERE o.contig=chr AND o.ref_start<=hi AND o.ref_end>=lo
GROUP BY p.sample_id,o.cell_id ORDER BY p.sample_id,o.cell_id;
CREATE MACRO aie_region_families(chr,lo,hi) AS TABLE
SELECT p.sample_id,f.cell_id,count(*) AS evidence_family_count
FROM families f CROSS JOIN evidence_policy p
WHERE f.contig=chr AND f.ref_start<=hi AND f.ref_end>=lo
GROUP BY p.sample_id,f.cell_id ORDER BY p.sample_id,f.cell_id;
CREATE MACRO aie_junction_labels(chr,d,a) AS TABLE
SELECT p.sample_id,o.cell_id,count(DISTINCT o.umi) AS umi_label_count
FROM counting_reads o JOIN junctions j USING(alignment_id) CROSS JOIN evidence_policy p
WHERE o.contig=chr AND j.donor=d AND j.acceptor=a
GROUP BY p.sample_id,o.cell_id ORDER BY p.sample_id,o.cell_id;
CREATE MACRO aie_junction_families(chr,d,a) AS TABLE
SELECT p.sample_id,f.cell_id,count(DISTINCT f.family_id) AS evidence_family_count
FROM families f JOIN family_junctions j USING(family_id) CROSS JOIN evidence_policy p
WHERE j.contig=chr AND j.donor=d AND j.acceptor=a
GROUP BY p.sample_id,f.cell_id ORDER BY p.sample_id,f.cell_id;
CHECKPOINT;
