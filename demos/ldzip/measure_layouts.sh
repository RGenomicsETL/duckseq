#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
mkdir -p work/perf/layout-runs
out=work/perf/layouts.tsv
printf 'row_group\tzstd\trep\tseconds\tpeak_rss_kb\tbytes\n' > "$out"
for rg in 16384 65536 122880 262144; do
  for z in 3 9 19; do
    for rep in 1 2 3; do
      stem="work/perf/layout-runs/rg${rg}-z${z}-r${rep}"
      /usr/bin/time -f '%e\t%M' -o "$stem.time" ./build.sh work/derived/region-1x "$rg" "$z" 8 >"$stem.out" 2>"$stem.err"
      read -r seconds rss < "$stem.time"
      parquet="work/derived/region-1x-b8-parquet-rg${rg}-z${z}"
      bytes=$(find "$parquet" -type f -printf '%s\n' | awk '{s += $1} END {print s+0}')
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rg" "$z" "$rep" "$seconds" "$rss" "$bytes" >> "$out"
    done
  done
done
printf 'Wrote %s\n' "$out"
