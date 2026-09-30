#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
mkdir -p work/perf/query-runs
out=work/perf/queries.tsv
printf 'region\tbits\tengine\toperation\trep\tlatency_ms\tpeak_rss_kb\n' > "$out"
for region in 1 2 4; do
  prefix="work/derived/region-${region}x"
  for bits in 8 16; do
    for engine in ldzip dbi cli; do
      for operation in pair_1000 pair_10000 tags_100 submatrix_1000 submatrix_5000; do
        for rep in 1 2 3; do
          stem="work/perf/query-runs/${region}x-b${bits}-${engine}-${operation}-r${rep}"
          attempt=1
          until timeout 300s /usr/bin/time -f '%e %M' -o "${stem}.time" \
            Rscript --vanilla bench_query.R "$prefix" "$bits" "$engine" "$operation" "$rep" \
            > "${stem}.out" 2> "${stem}.err"; do
            if (( attempt >= 2 )); then cat "${stem}.err" >&2; exit 1; fi
            attempt=$((attempt + 1))
          done
          read -r operation_out latency extra < "${stem}.out"
          read -r wall rss < "${stem}.time"
          child_rss=$(printf '%s\n' "$extra" | sed -n 's/.*CLI-child-RSS-kB=//p')
          [[ -z "$child_rss" ]] || rss=$child_rss
          printf '%sx\t%s\t%s\t%s\t%s\t%s\t%s\n' "$region" "$bits" "$engine" "$operation" "$rep" "$latency" "$rss" >> "$out"
        done
      done
    done
  done
done
printf 'Wrote %s\n' "$out"
