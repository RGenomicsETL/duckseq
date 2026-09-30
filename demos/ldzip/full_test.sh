#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
./setup.sh
./run_regions.sh
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
for n in 1 2 4; do
  for bits in 8 16; do
    Rscript --vanilla parity_regions.R "work/derived/region-${n}x" "$bits"
  done
done
./mutation_test.sh
