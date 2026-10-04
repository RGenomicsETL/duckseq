#!/usr/bin/env bash
# Require semantic failures against independent scalar/graph oracles; restore the source.
set -euo pipefail
cd "$(dirname "$0")"
backup=$(mktemp)
cp sql/prepare_evidence.sql "$backup"
restore() { cp "$backup" sql/prepare_evidence.sql; }
trap 'restore; rm -f "$backup"' EXIT
run=$(mktemp -d "$PWD/work/evidence-tests.XXXXXX")
AIE_EVIDENCE_TEST_DIR="$run/baseline" Rscript --vanilla check_evidence.R . > "$run/baseline.log" 2>&1
for mutant in cursor overlap strand primary; do
  restore
  case "$mutant" in
    cursor) perl -0pi -e "s/'M','D','N','=','X'/'M','D','=','X'/g" sql/prepare_evidence.sql ;;
    overlap) perl -0pi -e 's/ref_start>prior_end/ref_start>prior_end+50000/' sql/prepare_evidence.sql ;;
    strand) perl -0pi -e 's/\(FLAG & 16\) != 0 AS reverse/false AS reverse/' sql/prepare_evidence.sql ;;
    primary) perl -0pi -e 's/\(FLAG & 2308\) = 0 AS primary_mapped/(FLAG & 4) = 0 AS primary_mapped/' sql/prepare_evidence.sql ;;
  esac
  cmp -s sql/prepare_evidence.sql "$backup" && { echo "ERROR: unchanged $mutant" >&2; exit 1; }
  if AIE_EVIDENCE_TEST_DIR="$run/$mutant" Rscript --vanilla check_evidence.R . > "$run/$mutant.log" 2>&1; then
    echo "FAIL: $mutant survived" >&2; exit 1
  fi
  if ! grep -q 'identical(expected, actual) is not TRUE' "$run/$mutant.log"; then
    echo "ERROR: $mutant failed outside count parity; see $run/$mutant.log" >&2; exit 1
  fi
  echo "PASS: $mutant violates the independent counting contract"
done
restore
AIE_EVIDENCE_TEST_DIR="$run/restored" Rscript --vanilla check_evidence.R . > "$run/restored.log" 2>&1
echo "PASS: all four semantic mutants rejected; restored product passes ($run)"
