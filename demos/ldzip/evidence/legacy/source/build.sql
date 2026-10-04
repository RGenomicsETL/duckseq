-- Build the LDZip-equivalent Parquet tables from PLINK 2 output.
-- build.sh substitutes the @NAME@ placeholders; mutation_test.sh edits this file.

CREATE TEMP TABLE variants AS
SELECT row_number() OVER ()::INTEGER AS idx, "#CHROM" AS chrom, POS AS pos, ID AS id,
       REF AS ref, ALT AS alt, FILTER AS filter, INFO AS info
FROM read_csv('@PVAR@', delim = '\t', header = true, skip = @PVAR_SKIP@,
              columns = {'#CHROM': 'VARCHAR', 'POS': 'BIGINT', 'ID': 'VARCHAR', 'REF': 'VARCHAR',
                         'ALT': 'VARCHAR', 'FILTER': 'VARCHAR', 'INFO': 'VARCHAR'});

-- An LD row names each endpoint by ID, REF and ALT; the key must be unique.
SELECT error('PLINK variant keys are not unique')
WHERE (SELECT count(*) FROM variants) <> (SELECT count(DISTINCT (id, ref, alt)) FROM variants);

-- UNPHASED_R is parsed as float32, as LDZip's std::stof does.
CREATE TEMP TABLE pairs AS
SELECT a.idx AS i, b.idx AS j, v.UNPHASED_R AS r
FROM read_csv('@VCOR@', delim = '\t', header = true,
              columns = {'ID_A': 'VARCHAR', 'REF_A': 'VARCHAR', 'ALT_A': 'VARCHAR', 'ID_B': 'VARCHAR',
                         'REF_B': 'VARCHAR', 'ALT_B': 'VARCHAR', 'UNPHASED_R': 'FLOAT'}) v
LEFT JOIN variants a ON a.id = v.ID_A AND a.ref = v.REF_A AND a.alt = v.ALT_A
LEFT JOIN variants b ON b.id = v.ID_B AND b.ref = v.REF_B AND b.alt = v.ALT_B;

SELECT error('PLINK LD rows do not resolve to the full allele-template variant key')
WHERE EXISTS (SELECT 1 FROM pairs WHERE i IS NULL OR j IS NULL);
-- LDZip stores NaN as the integer type's minimum; these slices have none.
SELECT error('NaN LD values are not handled by this demo')
WHERE EXISTS (SELECT 1 FROM pairs WHERE isnan(r));

-- LDZip drops |r| < min, multiplies the float32 value by the scale in double
-- precision and applies std::llround; DuckDB's round(DOUBLE) also rounds half
-- away from zero. Both triangles are stored, plus any missing diagonal cell.
COPY variants TO '@OUT@/variants.parquet'
  (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL @ZSTD@, ROW_GROUP_SIZE @ROW_GROUP@, PARQUET_VERSION V2);

COPY (
  WITH kept AS (
    SELECT i, j, CAST(round(CAST(r AS DOUBLE) * @SCALE@) AS @INT_TYPE@) AS r_q
    FROM pairs WHERE abs(r) >= 0.0001
  ), both_triangles AS (
    SELECT i, j, r_q FROM kept
    UNION ALL
    SELECT j, i, r_q FROM kept WHERE i <> j
  )
  SELECT i, j, r_q FROM both_triangles
  UNION ALL
  SELECT idx, idx, @SCALE@::@INT_TYPE@ FROM variants
  WHERE idx NOT IN (SELECT i FROM both_triangles WHERE i = j)
  ORDER BY i, j
) TO '@OUT@/ld.parquet'
  (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL @ZSTD@, ROW_GROUP_SIZE @ROW_GROUP@, PARQUET_VERSION V2);
