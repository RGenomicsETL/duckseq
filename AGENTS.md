# duckseq contributor rules

## Thesis and evidence

Each demo tests whether standard genomic formats, DuckDB SQL over DuckHTS readers, and a small native kernel can match a tool built by hand. Keep the claim scoped to evidence in that demo's report.

A complete demo should include:

1. Exact parity on the original tool's own test data or tutorial.
2. Mutation tests that fail when a rule is implemented incorrectly.
3. Performance measurements under DuckHTS `STYLE.md`: 1×, 2× and 4× inputs, three fresh processes, peak RSS, and budgets declared before measurement.
4. An honest contrast table that includes cases where the original tool wins.

Do not present a demo as meeting a requirement that its report has not verified. Never invent benchmark values or weaken a comparison to obtain a pass.

## Repository boundaries

- `demos/peakwhere/` keeps its MIT licence and demo-specific rules in `demos/peakwhere/AGENTS.md`.
- `demos/aie/` contains the SQL demo and its demo-specific report and fixtures.
- Gravlax is built from the pinned upstream commit by `demos/aie/setup.sh`; generated build products are not committed.
- Root workflows own CI and Pages. Keep demo path filters narrow and preserve the same-origin-only browser app.
- The root `README.md` is generated from `README.Rmd`. Edit the source and render it; never hand-edit the generated file.

## Changes and verification

Use small, focused commits with imperative messages. Run the affected demo's tests and report exactly what was verified. Do not add a remote, publish branches, or perform other remote GitHub actions unless explicitly authorized.
