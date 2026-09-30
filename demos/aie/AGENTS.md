# AIE demo rules

This demo compares DuckDB SQL over DuckHTS reads with Gravlax AIE on the committed synthetic fixture. Keep claims scoped to the exact rules and input modes exercised by `REPORT.md`.

- `setup.sh` pins Gravlax and records resolved tool versions in `EXTENSIONS.txt`. Keep generated dependencies and test outputs ignored.
- `test.sh` compares SQL and Gravlax outputs exactly. Do not accept or normalize a mismatch.
- `mutation_test.sh` must kill every declared SQL mutant and restore the real SQL after each run.
- Update `REPORT.md` when fixture coverage or known semantic limits change.
- SQL and fixture generation are the demo's implementation. Keep shell for orchestration and use the existing DuckDB, samtools and Gravlax interfaces.
