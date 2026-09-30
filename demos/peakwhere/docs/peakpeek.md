# PeakPeek compatibility

How duckpeakwhere's **Peek** view relates to Sean Davis's
[PeakPeek](https://github.com/seandavi/peakpeek) at
[`a05b661`](https://github.com/seandavi/peakpeek/tree/a05b6615b1c51c41781b6a1f2081868fbc2b711e).
Expected values come from PeakPeek's own `examples/fixture.js`, `tests/stats.test.js`
and `SPEC.md` §2; see [`test/fixtures/peek/README.md`](../test/fixtures/peek/README.md).

| Rule | Status here |
|---|---|
| 0-based half-open BED/narrowPeak/broadPeak, gzip | Kept for tab-delimited inputs read by DuckHTS. |
| Zero width, negative/reversed/missing coordinates | Excluded from returned rows with a count by reason. |
| Min/median/mean/max/sum; even median averages two middle widths | Kept. UI means show up to two decimals; TSV keeps the numeric result. |
| Coordinate-only duplicates | Kept: count extra copies, ignoring name/score, without dropping them. |
| Merged bp and overlapping peaks | Kept: touching joins coverage but does not count as overlap; each duplicate copy overlaps. |
| Chromosomes | Kept: statistics distinguish original names; chart aliases align; numbered/X/Y/M/MT are main, others group as `other`. |
| Distribution | Kept: 30 shared log-spaced bins, last edge inclusive; equal widths expand the upper bound by 1; counts/percentages; no sampling. |
| Problems | Kept for returned intervals: duplicate/overlap/off-main/mixed-style counts and strictly >100 kb. Failed files show an error while other files remain usable. |
| CSV/TSV named-column tables and the 1-based toggle | Not ported: outside `read_bed`'s contract. |
| Scientific-notation coordinates and tolerant malformed-row parsing | Not ported: DuckHTS returns NULL for scientific notation and aborts on short rows. It cannot reproduce PeakPeek's rejected-line recovery. |
| Raw lines, skipped-line counts, exact format detection, rejection line numbers/text | Not available from `read_bed`; the UI says **excluded rows**, never invented line counts or diagnostics. |
| narrowPeak signal/p/q ranges and raw record previews | Not ported: `read_bed` exposes BED12 fields, so decimal columns 7/8 are NULL and extra fields are not retained. Extremes show parsed coordinates/name only. |
| Coordinates above 2,147,483,647 | Excluded with an explicit reason: cgranges has an int32 coordinate limit. |
| UI/delivery | Uses vendored Observable Plot, explicit Run, selected filenames/bundled labels, same-origin examples and local files. Editable extension-stripped labels, URL fetching and per-file removal are not ported. The large-file warning counts returned rows, not raw lines. |

## Why some rules can't be ported yet

These reader gaps cannot be repaired by statistics SQL because the necessary raw values
are not exposed. Limitation tests pin the behavior to prompt review when DuckHTS adds
those APIs; see its
[`read_bed` implementation](https://github.com/RGenomicsETL/duckhts/blob/41d5e899b3d2771a47c130ee003a49ddb4a2c4e2/src/interval_udf.c)
and the [browser-reader issue](https://github.com/RGenomicsETL/duckhts/issues/246).
No JavaScript parser substitutes for them: parsing belongs in DuckHTS
([duckhts#250](https://github.com/RGenomicsETL/duckhts/issues/250)).
