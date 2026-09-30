# duckpeakwhere house rules

`CLAUDE.md` is a symlink to this file; edit `AGENTS.md` only.

## What this is

A browser-only peak annotator: peakwhere's biology, computed as SQL over
[DuckHTS](https://github.com/RGenomicsETL/duckhts) in duckdb-wasm. It exists to show
DuckHTS's composition thesis: htslib supplies file formats and transport, DuckHTS
kernels supply interval mechanics, and SQL supplies everything else.

## Layout

- `src/annotate.js`: the whole analysis, one SQL statement per step. Start here.
- `src/app.js`, `index.html`, `src/style.css`: the page. `src/db.js`: duckdb-wasm setup.
  `src/duckhts-loader.js`: `loadDuckhts(conn, { baseUrl })`.
- `scripts/`: `stage-duckhts.mjs` (the only network step), `vendor.mjs`, `serve.mjs`.
- `test/`: Node test runner driving headless Chromium; `test/oracle.R`; `test/fixtures/`.
- `examples/`: the mouse thymus chr19 data and its provenance.
- `README.Rmd` renders `README.md`. `man/figures/logo.svg` is the hex sticker.
- `.github/workflows/test.yml` tests every push and PR; `.github/workflows/pages.yml` publishes
  `main` to <https://sounkou-bioinfo.github.io/duckpeakwhere/> (signed DuckHTS builds only).

## Rules

1. **SQL first.** File reading, contig matching and overlap go through DuckHTS
   functions. Category logic is plain SQL. Do not add a JavaScript parser, interval tree
   or overlap engine. If DuckHTS lacks something, open an issue on DuckHTS rather than
   working around it here.
2. **Keep peakwhere's biology.** Promoter window, peak-centre and base-pair counting,
   priority order and chromosome handling follow peakwhere's rules, as encoded in
   `test/fixtures/expected.json`. A change to them is a change to the expected answers
   and needs its own justification.
3. **No runtime network.** The page loads nothing from outside its own origin, and a
   test enforces this. Build-time downloads go through a staging script that pins exact
   versions and checks sha256 values. `vendor/` is generated, never committed or
   hand-edited.
4. **Signed DuckHTS only.** Load the community-signed builds with
   `allow_unsigned_extensions` off.
5. **Independent oracles.** Expected numbers come from peakwhere's hand-worked fixture or
   from `test/oracle.R`, which shares no code or engine with the SQL. Never use the SQL's
   own output as its expectation, and never loosen a comparison to get a pass.
6. **Known limits are tests.** A DuckHTS limitation the app works around gets a test
   that fails once the limitation is gone, plus a link to the DuckHTS issue.
7. **No Python.** JavaScript for the app and tests; base R for oracles and README
   rendering.
8. **README.md is rendered.** Edit `README.Rmd` and run `make readme`; never hand-edit
   `README.md`.
9. **Credit.** Keep the link to Sean Davis's peakwhere and his copyright line in
   `LICENSE`.
10. **Small and readable.** No planning documents, agent state or ADR piles in the repo;
    git history and GitHub issues hold the path. Keep changes focused, and state in the
    commit or PR which checks were actually run.
    Upstream provenance cites code, tests and fixtures at a pinned commit, never
    upstream process documents (ADRs, specs' decision logs, ledgers); state our rules
    in our own words.

## Checks

```bash
npm ci && npm run stage && npm run vendor
npm test                 # headless Chromium
Rscript test/oracle.R && git diff --exit-code test/fixtures/thymus-expected.json
make readme              # needs R with knitr, rmarkdown, duckknit and Rduckhts
```
