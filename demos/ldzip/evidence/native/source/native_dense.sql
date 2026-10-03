WITH cfg AS (
  SELECT getvariable('matrix_n')::BIGINT AS n,
         getvariable('quant_scale')::BIGINT AS scale
),
grid AS (
  SELECT rows.i::BIGINT AS i, columns.j::BIGINT AS j
  FROM range(1, (SELECT n FROM cfg) + 1) AS rows(i)
  CROSS JOIN range(1, (SELECT n FROM cfg) + 1) AS columns(j)
),
sparse AS (
  SELECT i::BIGINT AS i, j::BIGINT AS j, r_q::BIGINT AS r_q
  FROM read_parquet(getvariable('ld_path'))
  WHERE i BETWEEN 1 AND (SELECT n FROM cfg)
    AND j BETWEEN 1 AND (SELECT n FROM cfg)
)
SELECT grid.j,
       list(CASE WHEN grid.i = grid.j THEN 1.0::DOUBLE
                 ELSE coalesce(
                   CAST(CAST(sparse.r_q AS REAL) /
                        (SELECT scale::REAL FROM cfg) AS REAL)::DOUBLE,
                   0.0::DOUBLE)
            END ORDER BY grid.i) AS vals
FROM grid
LEFT JOIN sparse ON sparse.i = grid.i AND sparse.j = grid.j
GROUP BY grid.j
ORDER BY grid.j;

WITH cfg AS (
  SELECT getvariable('matrix_n')::BIGINT AS n,
         getvariable('quant_scale')::BIGINT AS scale
),
seed_rows AS (
  SELECT 0::BIGINT AS i, columns.j::BIGINT AS j, 0::BIGINT AS q,
         cfg.n AS n, cfg.scale AS scale
  FROM cfg
  CROSS JOIN range(1, cfg.n + 1) AS columns(j)
),
sparse_rows AS (
  SELECT i::BIGINT AS i, j::BIGINT AS j, r_q::BIGINT AS q,
         cfg.n AS n, cfg.scale AS scale
  FROM read_parquet(getvariable('ld_path'))
  CROSS JOIN cfg
  WHERE i BETWEEN 1 AND cfg.n AND j BETWEEN 1 AND cfg.n
),
aggregate_input AS (
  SELECT i, j, q, n, scale FROM seed_rows
  UNION ALL
  SELECT i, j, q, n, scale FROM sparse_rows
)
SELECT j, ld_dense_column(i, j, q, n, scale) AS vals
FROM aggregate_input
GROUP BY j
ORDER BY j;
