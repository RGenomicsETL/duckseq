LOAD '/usr/lib/R/site-library/Rduckhts/duckhts_extension/build/duckhts.duckdb_extension';
SET threads=1;
SET memory_limit='1GiB';
SET max_temp_directory_size='512MiB';
CREATE TEMP TABLE source AS
SELECT QNAME,FLAG,RNAME,POS,CIGAR,CB,CR,
       AUXILIARY_TAGS['UB']::VARCHAR AS UB,
       AUXILIARY_TAGS['UR']::VARCHAR AS UR
FROM read_bam('pilot.bam', standard_tags := TRUE, auxiliary_tags := TRUE);
COPY (SELECT count(*) AS records,
             count(*) FILTER (WHERE CB !~ '^[ACGT]{16}-1$') AS unsupported_cb_format,
             count(*) FILTER (WHERE CR<>substr(CB,1,16)) AS raw_corrected_barcode_disagreements,
             count(*) FILTER (WHERE UR<>UB) AS raw_corrected_umi_disagreements,
             count(DISTINCT substr(CB,1,16)) AS corrected_barcodes,
             count(*) FILTER (WHERE UR ~ '.*N.*') AS raw_umi_contains_n
      FROM source) TO 'tag-summary.csv' (HEADER,DELIMITER ',');
COPY (SELECT DISTINCT substr(CB,1,16) FROM source ORDER BY 1)
  TO 'whitelist.txt' (HEADER FALSE);
COPY (SELECT 'pilot'::VARCHAR AS sample_id,row_number() OVER (ORDER BY QNAME,FLAG,RNAME,POS,CIGAR) AS alignment_id,
             QNAME AS read_id,FLAG AS flag,RNAME AS contig,POS AS pos_1based,CIGAR AS cigar,
             substr(CB,1,16) AS cell_barcode,UB AS umi,CR AS raw_cell_barcode,UR AS raw_umi
      FROM source ORDER BY RNAME,POS,QNAME,FLAG) TO 'alignments.parquet' (FORMAT PARQUET);
