#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
prefix=work/derived/region-1x
for mutant in wrong-rounding shifted-index upper-triangle wrong-threshold ignore-allele-template; do
  echo "Testing actual SQL mutant: $mutant"
  LDZIP_MUTANT="$mutant" Rscript --vanilla build_parquet.R "$prefix" 262144 9 8 >/dev/null
  if Rscript --vanilla parity_regions.R "$prefix" 8 >"work/perf/mutation-${mutant}.log" 2>&1; then
    echo "FAIL mutant preserved 1x parity: $mutant" >&2
    exit 1
  fi
  grep -E 'Error:|Error in' "work/perf/mutation-${mutant}.log" | tail -1 || true
  echo "PASS actual SQL mutant fails 1x parity: $mutant"
done
Rscript --vanilla build_parquet.R "$prefix" 262144 9 8 >/dev/null
Rscript --vanilla parity_regions.R "$prefix" 8
echo "PASS rebuilt 1x SQL pipeline after mutation checks"
