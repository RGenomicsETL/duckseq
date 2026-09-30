SELECT capability, availability_state, detail
FROM read_parquet('work/capabilities.parquet')
ORDER BY capability;

-- Empty results in an evidence relation are not evidence of biological zero.
-- Ask for available observations and return an explicit bounded-state row.
SELECT capability, availability_state, detail
FROM read_parquet('work/capabilities.parquet')
WHERE capability='biological_absence';
