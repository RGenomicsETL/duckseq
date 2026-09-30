#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PLINK2=${PLINK2:-$PWD/.cache/plink2-bin}
LDZIP=${LDZIP:-$PWD/.ldzip/cpp/bin/ldzip}
R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
export R_LIBS_USER
[[ -s work/input/chr20.vcf.gz && -s work/input/samples.panel ]] || { echo "Run ./setup.sh first" >&2; exit 1; }
[[ -s work/derived/chr20.pgen ]] || "$PLINK2" --vcf work/input/chr20.vcf.gz --make-pgen --threads 2 --out work/derived/chr20
awk '$3 == "EUR" {print $1}' work/input/samples.panel > work/input/EUR.txt

for multiple in 1 2 4; do
  start=20000000
  end=$((start + 250000 * multiple))
  prefix="work/derived/region-${multiple}x"
  "$PLINK2" --pfile work/derived/chr20 --chr 20 --from-bp "$start" --to-bp "$end" \
    --make-just-pvar --threads 2 --out "${prefix}-vars"
  awk '!/^#/ {print $3}' "${prefix}-vars.pvar" > "${prefix}.ids"
  "$PLINK2" --pfile work/derived/chr20 --extract "${prefix}.ids" --keep work/input/EUR.txt \
    --ld-window-kb 1000 --ld-window-r2 0.01 \
    --r-unphased ref-based cols=id,ref,alt --threads 2 --out "$prefix"
  for bits in 8 16; do
    "$LDZIP" compress plinkTabular --ld_file "${prefix}.vcor" \
      --snp_file "${prefix}-vars.pvar" --output_prefix "${prefix}-b${bits}" \
      --bits "$bits" --min 0.0001 --min_col UNPHASED_R
    Rscript --vanilla -e 'library(LDZipMatrix); x <- LDZipMatrix(commandArgs(TRUE)[[1L]]); buildIndex(x)' "${prefix}-b${bits}"
    Rscript --vanilla build_parquet.R "$prefix" 122880 3 "$bits"
  done
done
