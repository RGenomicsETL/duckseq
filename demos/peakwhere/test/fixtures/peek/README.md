# PeakPeek oracle

`expected.json` transcribes PeakPeek's independently worked answers at
[`a05b661`](https://github.com/seandavi/peakpeek/tree/a05b6615b1c51c41781b6a1f2081868fbc2b711e):
`examples/fixture.js`, `tests/stats.test.js`, and `SPEC.md` §2/§7. The full ENCODE
means are rounded in that spec; tests also compare the exact mean to its stated
sum divided by count. The fixture's histogram counts come from that revision's
`PeakPeek.summarise` over its hand-worked widths `[1,10,50,100,100,100,100,300,1000]`,
using its default 30 bins. No expectation comes from duckpeakwhere's SQL.

`original.bed` is PeakPeek's unmodified malformed-input fixture. DuckHTS aborts on its
short final row. `accepted.bed` contains precisely the nine accepted intervals named
by PeakPeek's fixture oracle, with its scientific-notation coordinate written as the
oracle's integer value, 1000. It tests statistics, not parser compatibility. Separate
limitation tests cover scientific notation and short rows.

The whole-genome thymus inputs are hash-checked by `scripts/stage-peek-examples.mjs`
against `bench/manifest.json`. They are not the chr19 subsets under `examples/`.
The small inline fixtures in `test/peek.test.js` exercise the rules in PeakPeek's
`tests/stats.test.js`: touching versus overlapping, nesting, coordinate-only
duplicates, mixed chromosome names, and strict widths-over-100-kb warnings.
