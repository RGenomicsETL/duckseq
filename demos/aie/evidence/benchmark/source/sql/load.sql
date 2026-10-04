LOAD 'ext/duckhts.duckdb_extension';

CREATE OR REPLACE TEMP TABLE bam_rows AS
SELECT 'sample_a'::VARCHAR AS sample_id, 'sample_a.aie'::VARCHAR AS archive_id, 'GRCh38-fixture'::VARCHAR AS assembly,
       '1-based-inclusive'::VARCHAR AS input_coordinates, *
FROM read_bam('work/sample_a.bam', standard_tags := TRUE, auxiliary_tags := TRUE)
UNION ALL
SELECT 'sample_b', 'sample_b.aie', 'GRCh38-fixture', '1-based-inclusive', *
FROM read_bam('work/sample_b.bam', standard_tags := TRUE, auxiliary_tags := TRUE);

CREATE OR REPLACE TEMP TABLE alignment_rows AS
SELECT row_number() OVER (PARTITION BY sample_id ORDER BY QNAME, FLAG, RNAME, POS, CIGAR, HI) AS alignment_id,
       * FROM bam_rows;

COPY (
  SELECT DISTINCT sample_id, archive_id, assembly, input_coordinates
  FROM bam_rows ORDER BY sample_id
) TO 'work/sample_archive.parquet' (FORMAT PARQUET);

COPY (
  SELECT sample_id, alignment_id, archive_id, QNAME AS read_id, FLAG::UINTEGER AS flag,
         RNAME AS contig, POS::BIGINT AS pos_1based, MAPQ::INTEGER AS mapq,
         CIGAR AS cigar, NH::INTEGER AS nh, HI::INTEGER AS hi,
         CB AS cell_barcode, AUXILIARY_TAGS['UB'] AS umi, CR AS raw_cell_barcode, AUXILIARY_TAGS['UR'] AS raw_umi,
         SAMPLE_ID AS bam_sample_id, READ_GROUP_ID AS read_group_id,
         (FLAG & 16) != 0 AS is_reverse,
         (FLAG & 256) != 0 AS is_secondary,
         SEQ AS sequence, QUAL AS quality
  FROM alignment_rows
  ORDER BY sample_id, contig, pos_1based, read_id, flag
) TO 'work/alignments.parquet' (FORMAT PARQUET);

COPY (
  SELECT sample_id, alignment_id, QNAME AS read_id, flag, RNAME AS contig, POS AS pos_1based,
         unnest(regexp_extract_all(cigar, '[0-9]+[MIDNSHP=X]')) AS operation_token,
         generate_subscripts(regexp_extract_all(cigar, '[0-9]+[MIDNSHP=X]'), 1)::UINTEGER AS operation_order
  FROM alignment_rows
  ORDER BY sample_id, contig, pos_1based, read_id, flag
) TO 'work/cigar_operations.parquet' (FORMAT PARQUET);

COPY (
  WITH tokens AS (
    SELECT *, right(operation_token,1) AS op,
           left(operation_token,length(operation_token)-1)::BIGINT AS op_length
    FROM read_parquet('work/cigar_operations.parquet')
  ), positioned AS (
    SELECT *, coalesce(sum(CASE WHEN op IN ('M','D','N','=','X') THEN op_length ELSE 0 END)
      OVER (PARTITION BY sample_id,alignment_id ORDER BY operation_order
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS ref_before
    FROM tokens
  )
  SELECT sample_id, alignment_id, read_id, flag, contig, pos_1based,
         struct_pack(start := list(pos_1based+ref_before ORDER BY operation_order)
                              FILTER (WHERE op IN ('M','=','X')),
                     width := list(op_length ORDER BY operation_order)
                              FILTER (WHERE op IN ('M','=','X'))) AS blocks,
         list(op ORDER BY operation_order) AS operation_codes
  FROM positioned GROUP BY sample_id,alignment_id,read_id,flag,contig,pos_1based
  ORDER BY sample_id,contig,pos_1based,read_id,flag
) TO 'work/read_geometry.parquet' (FORMAT PARQUET);

COPY (
  SELECT sample_id, alignment_id, read_id, cell_barcode AS cell_id, umi AS umi_id,
         'raw-membership; correction not applied by this relation'::VARCHAR AS policy
  FROM read_parquet('work/alignments.parquet')
) TO 'work/cell_umi_membership.parquet' (FORMAT PARQUET);

COPY (
  SELECT sample_id, alignment_id, read_id, nh AS declared_placement_count,
         hi AS placement_ordinal,
         CASE WHEN nh > 0 THEN 1.0 / nh ELSE NULL END::DOUBLE AS equal_placement_weight,
         is_secondary
  FROM read_parquet('work/alignments.parquet')
) TO 'work/placement_alternatives.parquet' (FORMAT PARQUET);

COPY (
  SELECT sample_id, archive_id, assembly, 'chr1'::VARCHAR AS contig,
         100::BIGINT AS contig_length, '+'::VARCHAR AS strand_convention,
         'BAM POS 1-based; stored start inclusive; BED-style output must subtract one'::VARCHAR AS coordinate_note
  FROM read_parquet('work/sample_archive.parquet')
) TO 'work/reference_dictionary.parquet' (FORMAT PARQUET);

COPY (
  SELECT 'sequence_and_quality_retained_in_alignment_relation'::VARCHAR AS capability,
         'available'::VARCHAR AS availability_state,
         'sequence, quality and CB/UB/CIGAR retained'::VARCHAR AS detail
  UNION ALL SELECT 'corrected_barcode_policy', 'available', 'raw CR/UR and CB/UB are independently stored; no SQL correction is applied'
  UNION ALL SELECT 'biological_absence', 'unavailable', 'no observation cannot establish biological zero'
  UNION ALL SELECT 'alignment alternatives', 'partially_available', 'records observed in BAM retained; unobserved alternatives cannot be reconstructed'
) TO 'work/capabilities.parquet' (FORMAT PARQUET);
