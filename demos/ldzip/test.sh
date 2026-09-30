#!/usr/bin/env bash
# CI test: the LDZipMatrix bundled fixture, then the full build and parity
# pipeline on a committed 500-variant chr20 slice, then the build mutants.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .ldzip/cpp/bin/ldzip || ! -d .rlib/LDZipMatrix || ! -x .cache/duckdb ]]; then
  ./setup.sh --no-data
fi
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
Rscript --vanilla parity.R

prefix=work/fixture-region/region-mini
rm -rf work/fixture-region
mkdir -p work/fixture-region
gzip -dc fixtures/region-mini-vars.pvar.gz > "${prefix}-vars.pvar"
gzip -dc fixtures/region-mini.vcor.gz > "${prefix}.vcor"
for bits in 8 16; do
  .ldzip/cpp/bin/ldzip compress plinkTabular --ld_file "${prefix}.vcor" \
    --snp_file "${prefix}-vars.pvar" --output_prefix "${prefix}-b${bits}" \
    --bits "$bits" --min 0.0001 --min_col UNPHASED_R > /dev/null
  ./build.sh "$prefix" 262144 9 "$bits" > /dev/null
  Rscript --vanilla parity_regions.R "$prefix" "$bits"
done
./mutation_test.sh "$prefix"
