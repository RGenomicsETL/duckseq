SET threads=1;
CREATE TEMP TABLE observations AS SELECT * FROM read_parquet('alignments.parquet');
COPY (SELECT cell_barcode AS cell,count(DISTINCT raw_umi) AS umi_count
      FROM observations GROUP BY cell_barcode ORDER BY 1)
TO 'cb-ur-counts.csv' (HEADER,DELIMITER ',');
COPY (SELECT raw_cell_barcode AS cell,count(DISTINCT raw_umi) AS umi_count
      FROM observations GROUP BY raw_cell_barcode ORDER BY 1)
TO 'cr-ur-counts.csv' (HEADER,DELIMITER ',');
COPY (SELECT cell_barcode AS cell,count(DISTINCT umi) AS umi_count
      FROM observations GROUP BY cell_barcode ORDER BY 1)
TO 'cb-ub-counts.csv' (HEADER,DELIMITER ',');
