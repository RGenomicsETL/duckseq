#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .ldzip/cpp/bin/ldzip || ! -d .rlib/LDZipMatrix ]]; then
  ./setup.sh --no-data
fi
R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}" Rscript --vanilla parity.R
./mutation_test.sh
