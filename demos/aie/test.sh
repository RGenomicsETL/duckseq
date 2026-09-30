#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
eval "$(./setup.sh)"
AIE=.gravlax/target/release/aie

mkdir -p work
failures=0
check_equal() {
  local label="$1" expected="$2" observed="$3"
  if [[ "$expected" != "$observed" ]]; then
    printf 'FAIL %s: SQL=%s AIE=%s\n' "$label" "$expected" "$observed" >&2
    failures=$((failures + 1))
  fi
}
./fixture/build.sh > work/fixture-build.log 2>&1
"$DUCKDB" -unsigned < sql/load.sql > work/load.log
for query in region junction jset availability annotation_counts; do
  "$DUCKDB" -unsigned -csv < "sql/${query}.sql" > "work/sql-${query}.csv"
done

for sample in a b; do
  archive="work/sample_${sample}.aie"
  cell=$(if [[ "$sample" == a ]]; then printf AAAAAAAAAAAAAAAA; else printf CCCCCCCCCCCCCCCC; fi)
  "$AIE" query "$archive" region chr1:1-100 --format tsv --top 0 > "work/aie-${sample}-region.tsv" 2> "work/aie-${sample}-region.log"
  "$AIE" query "$archive" junction chr1:14-24 --format tsv --top 0 > "work/aie-${sample}-junction.tsv" 2> "work/aie-${sample}-junction.log"
  sql_region=$(awk -F, -v c="$cell" '$2==c {print $3}' work/sql-region.csv)
  oracle_region=$(awk -F '\t' -v c="$cell" '$1=="cell" && $2==c {print $3}' "work/aie-${sample}-region.tsv")
  sql_junction=$(awk -F, -v c="$cell" '$2==c {print $3}' work/sql-junction.csv)
  oracle_junction=$(awk -F '\t' -v c="$cell" '$1=="cell" && $2==c {print $3}' "work/aie-${sample}-junction.tsv")
  check_equal "region sample_${sample}" "$sql_region" "$oracle_region"
  check_equal "junction sample_${sample}" "$sql_junction" "$oracle_junction"
done

for sample in a b; do
  cell=$(if [[ "$sample" == a ]]; then printf AAAAAAAAAAAAAAAA; else printf CCCCCCCCCCCCCCCC; fi)
  printf '%s\n' "$cell" > "work/cells-${sample}.txt"
  for version in v1 v2; do
    "$AIE" replay-rows "work/sample_${sample}.aie" --gtf "fixture/annotation-${version}.gtf" \
      --barcodes "work/cells-${sample}.txt" --out-dir "work/replay-${sample}-${version}" \
      > "work/replay-${sample}-${version}.log" 2>&1
  done
  "$AIE" compare-annotations "work/sample_${sample}.aie" --annotation-a fixture/annotation-v1.gtf \
    --annotation-b fixture/annotation-v2.gtf --assembly GRCh38-fixture \
    --annotation-a-label v1 --annotation-b-label v2 --format json \
    > "work/annotation-comparison-${sample}.json"
done
"$AIE" query work/sample_a.aie jset --include chr1:14-24 --exclude chr1:29-39 \
  --format tsv --top 0 > work/aie-jset.tsv 2> work/aie-jset.log

sql_include=$(awk -F, '$1=="sample_a" && $5=="false" && $4=="true" {n++} END {print n+0}' work/sql-jset.csv)
aie_include=$(sed -n 's/^# summary=//p' work/aie-jset.tsv | jq -r '.totals.include_only')
check_equal "jset include-only" "$sql_include" "$aie_include"
sql_both=$(awk -F, '$1=="sample_a" && $6=="true" {n++} END {print n+0}' work/sql-jset.csv)
aie_both=$(sed -n 's/^# summary=//p' work/aie-jset.tsv | jq -r '.totals.both')
check_equal "jset both" "$sql_both" "$aie_both"

for sample in a b; do
  for version in v1 v2; do
    awk -F '[ \t]+' 'FNR==NR {gene[FNR]=$1; next} FNR<=3 {next} NF==3 {count[$1]+=$3} END {for (i in count) print gene[i] "," count[i]}' \
      "work/replay-${sample}-${version}/features.tsv" "work/replay-${sample}-${version}/matrix.mtx" | sort \
      > "work/aie-annotation-${sample}-${version}.csv"
    column=4
    [[ "$version" == v2 ]] && column=5
    awk -F, -v s="sample_${sample}" -v c="$column" '$1==s && $c+0>0 {print $3 "," $c}' \
      work/sql-annotation_counts.csv | sort > "work/sql-annotation-${sample}-${version}.csv"
    if ! diff -u "work/aie-annotation-${sample}-${version}.csv" \
        "work/sql-annotation-${sample}-${version}.csv"; then
      printf 'FAIL annotation sample_%s %s\n' "$sample" "$version" >&2
      failures=$((failures + 1))
    fi
  done
  jq -r '.data.count_deltas.rows[] | select(.[7] != 0) | .[2] + "," + (.[7] | tostring)' \
    "work/annotation-comparison-${sample}.json" | sort > "work/aie-delta-${sample}.csv"
  awk -F, -v s="sample_${sample}" '$1==s && $6+0!=0 {print $3 "," $6}' \
    work/sql-annotation_counts.csv | sort > "work/sql-delta-${sample}.csv"
  if ! diff -u "work/aie-delta-${sample}.csv" "work/sql-delta-${sample}.csv"; then
    printf 'FAIL annotation deltas sample_%s\n' "$sample" >&2
    failures=$((failures + 1))
  fi
  printf 'AIE compare-annotations signed deltas sample_%s: ' "$sample"
  jq -c '.data.count_deltas.rows' "work/annotation-comparison-${sample}.json"
done
if (( failures )); then
  printf 'FAIL %s comparison(s) differ from Gravlax.\n' "$failures" >&2
  exit 1
fi
printf 'PASS region, junction, jset, and annotation counts match Gravlax for both samples\n'
