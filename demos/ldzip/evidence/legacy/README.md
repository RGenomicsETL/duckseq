# Historical build measurements

`build.tsv` is the original per-process build table used for the report's 8/16-bit chr20 250 kb / 500 kb / 1 Mb region comparisons. Each engine/region/bit cell has three fresh processes. The regions contain 5,764 / 11,590 / 22,833 variants and do not form an exact row-count ladder.

`source/` contains the build SQL, shell orchestration, measurement driver and authored report describing the recorded environment and inputs. Charts use the raw build rows, not invented or rounded values from the prose. RSS charts show the maximum of the three process peaks; the historical report table gives their median.

The retained output representations differ. LDZip compression excludes SQLite-index construction. DuckDB used its default thread count. The legacy harness did not enforce every declared budget; these measurements do not establish DuckHTS STYLE qualification. This archive contains the per-process TSV, not every original stdout/stderr receipt. The native matrix suite has its separate complete evidence archive and explicit resource-failure records.

Verify this archive with `sha256sum -c SHA256SUMS` from this directory. Rendering charts does not run engines or modify these receipts.
