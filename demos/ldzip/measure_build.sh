#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PLINK2=${PLINK2:-$PWD/.cache/plink2-bin}
LDZIP=${LDZIP:-$PWD/.ldzip/cpp/bin/ldzip}
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
mkdir -p work/perf/scratch
out=work/perf/build.tsv
printf 'region\tbits\tformat\trep\telapsed_s\tmax_rss_kb\tbytes\n' > "$out"
size_tree() { find "$1" -type f -printf '%s\n' | awk '{s += $1} END {print s+0}'; }
for region in 1 2 4; do
  prefix="work/derived/region-${region}x"
  for bits in 8 16; do
    for rep in 1 2 3; do
      scratch="work/perf/scratch/${region}x-b${bits}-r${rep}"
      rm -rf "$scratch"
      mkdir -p "$scratch"
      log="$scratch/ldzip.log"
      /usr/bin/time -f '%e\t%M' -o "$scratch/time.tsv" \
        "$LDZIP" compress plinkTabular --ld_file "${prefix}.vcor" \
        --snp_file "${prefix}-vars.pvar" --output_prefix "$scratch/matrix" \
        --bits "$bits" --min 0.0001 --min_col UNPHASED_R > "$log" 2>&1
      read -r seconds rss < "$scratch/time.tsv"
      bytes=$(du -bc "$scratch"/matrix* | tail -1 | awk '{print $1}')
      printf '%sx\t%s\tLDZip\t%s\t%s\t%s\t%s\n' "$region" "$bits" "$rep" "$seconds" "$rss" "$bytes" >> "$out"
    done
    for rep in 1 2 3; do
      log="work/perf/scratch/${region}x-b${bits}-parquet-r${rep}.log"
      /usr/bin/time -f '%e\t%M' -o "${log}.time" \
        Rscript --vanilla build_parquet.R "$prefix" 262144 9 "$bits" > "$log" 2>&1
      read -r seconds rss < "${log}.time"
      parquet="${prefix}-b${bits}-parquet-rg262144-z9"
      bytes=$(size_tree "$parquet")
      printf '%sx\t%s\tDuckDB-COPY\t%s\t%s\t%s\t%s\n' "$region" "$bits" "$rep" "$seconds" "$rss" "$bytes" >> "$out"
    done
  done
done
printf 'Wrote %s\n' "$out"
