#!/usr/bin/env bash
# Independent BAM/htslib + awk exact-tag oracle; no DuckHTS geometry in the reference.
set -euo pipefail
[[ $# -eq 3 ]] || { echo 'usage: check_real_labels.sh BAM CACHE.duckdb NEW_OUTPUT_DIR' >&2; exit 2; }
bam=$(realpath "$1")
cache=$(realpath "$2")
out=$(realpath -m "$3")
[[ ! -e "$out" ]] || { echo 'Output directory must be new' >&2; exit 2; }
mkdir -p "$out"
cd "$out"
export LC_ALL=C
samtools index "$bam"
for kind in full window; do
  hi=248956422; [[ "$kind" == window ]] && hi=3000000
  samtools view "$bam" "1:1-$hi" |
    awk -F '\t' '
    { cb="";ur="";for(i=12;i<=NF;i++){if(substr($i,1,5)=="CB:Z:")cb=substr($i,6);if(substr($i,1,5)=="UR:Z:")ur=substr($i,6)}
      if(cb!="" && ur!="")pair[cb SUBSEP ur]=1 }
    END{for(k in pair){split(k,p,SUBSEP);count[p[1]]++}for(c in count)print c "," count[c]}' |
    sort > "reference-$kind.csv"
  "${DUCKDB:-duckdb}" -bail -csv "$cache" -c "SELECT cell_id,umi_label_count FROM aie_region_labels('1',1,$hi);" > "sql-$kind.csv"
  # CSV header is a representation difference; compare exact cell/count records.
  tail -n +2 "sql-$kind.csv" | sort > "sql-$kind-data.csv"
  diff -u "reference-$kind.csv" "sql-$kind-data.csv" > "$kind.diff"
  echo "PASS: real $kind raw-UMI labels match independent samtools/awk"
done
