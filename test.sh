#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
AIE=.gravlax/target/release/aie
DUCKDB=/root/.local/bin/duckdb
GRAVLAX_COMMIT=75b8d6c01064ba92af295543d50230429774e170

mkdir -p work
if [[ ! -d .gravlax/.git ]]; then
  git clone https://github.com/COMBINE-lab/gravlax.git .gravlax
  git -C .gravlax checkout "$GRAVLAX_COMMIT"
fi
if [[ "$(git -C .gravlax rev-parse HEAD)" != "$GRAVLAX_COMMIT" ]]; then
  echo "Expected Gravlax $GRAVLAX_COMMIT in .gravlax" >&2
  exit 1
fi
if [[ ! -x "$AIE" ]]; then
  cargo build --release --manifest-path .gravlax/Cargo.toml
fi

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
  [[ "$sql_region" == "$oracle_region" ]] || { echo "region mismatch sample_${sample}: SQL=$sql_region AIE=$oracle_region"; exit 1; }
  [[ "$sql_junction" == "$oracle_junction" ]] || { echo "junction mismatch sample_${sample}: SQL=$sql_junction AIE=$oracle_junction"; exit 1; }
done

printf 'AAAAAAAAAAAAAAAA\n' > work/cells-a.txt
for version in v1 v2; do
  "$AIE" replay-rows work/sample_a.aie --gtf "fixture/annotation-${version}.gtf" \
    --barcodes work/cells-a.txt --out-dir "work/replay-a-${version}" > "work/replay-${version}.log" 2>&1
done
"$AIE" compare-annotations work/sample_a.aie --annotation-a fixture/annotation-v1.gtf \
  --annotation-b fixture/annotation-v2.gtf --assembly GRCh38-fixture \
  --annotation-a-label v1 --annotation-b-label v2 --format json > work/annotation-comparison.json
"$AIE" query work/sample_a.aie jset --include chr1:14-24 --exclude chr1:29-39 \
  --format tsv --top 0 > work/aie-jset.tsv 2> work/aie-jset.log

printf 'PASS region and junction counts match Gravlax for both samples\n'

sql_include=$(awk -F, '$1=="sample_a" && $5=="false" && $4=="true" {n++} END {print n+0}' work/sql-jset.csv)
aie_include=$(sed -n 's/^# summary=//p' work/aie-jset.tsv | jq -r '.totals.include_only')
[[ "$sql_include" == "$aie_include" ]] || { echo "jset include-only mismatch: SQL=$sql_include AIE=$aie_include"; exit 1; }

parity=0
for version in v1 v2; do
  awk -F '[ \t]+' 'FNR==NR {gene[FNR]=$1; next} FNR<=3 {next} NF==3 {count[$1]+=$3} END {for (i in count) print gene[i] "," count[i]}' \
    "work/replay-a-${version}/features.tsv" "work/replay-a-${version}/matrix.mtx" | sort > "work/aie-annotation-${version}.csv"
done
printf 'AIE compare-annotations signed deltas: '
jq -c '.data.count_deltas.rows' work/annotation-comparison.json
printf 'Observed SQL-vs-AIE annotation results (sample_a):\n'
for version in v1 v2; do
  column=4
  [[ "$version" == v2 ]] && column=5
  awk -F, -v c="$column" '$1=="sample_a" && $c+0>0 {print $3 "," $c}' work/sql-annotation_counts.csv | sort > "work/sql-annotation-${version}.csv"
  if ! diff -u "work/aie-annotation-${version}.csv" "work/sql-annotation-${version}.csv"; then
    parity=1
  fi
done
if (( parity )); then
  echo 'Annotation comparison failed: SQL overlap/UMI aggregation differs from Gravlax replay.'
  echo 'Gravlax requires transcript-concordant junction assignment, its locus-level representative rules, and per-gene one-mismatch UMI collapse.'
  exit 1
fi
printf 'PASS region, junction, jset, and annotation counts match Gravlax\n'
