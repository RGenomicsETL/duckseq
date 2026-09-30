#!/usr/bin/env bash
# Usage: allele_key_check.sh <region-prefix>
# Rewrites variant IDs to CHROM:POS, which collide at multi-allelic sites (LDZip
# aborts on such files), builds them with $LDZIP_BUILD_SQL (default build.sql)
# and requires the same 8-bit ld table that build.sql writes from the original IDs.
set -euo pipefail
cd "$(dirname "$0")"
prefix=${1:?Usage: allele_key_check.sh <region-prefix>}
dir=work/allele-key
rm -rf "$dir"
mkdir -p "$dir"
header_line=$(grep -n -m1 $'^#CHROM\t' "${prefix}-vars.pvar" | cut -d: -f1)
cp "${prefix}-vars.pvar" "$dir/unique-vars.pvar"
cp "${prefix}.vcor" "$dir/unique.vcor"
awk -F'\t' -v OFS='\t' -v h="$header_line" 'NR <= h {print; next} {$3 = $1 ":" $2; print}' \
  "${prefix}-vars.pvar" > "$dir/posid-vars.pvar"
awk -F'\t' -v OFS='\t' -v h="$header_line" '
  NR == FNR {if (FNR > h) id[$3 "\t" $4 "\t" $5] = $1 ":" $2; next}
  FNR == 1 {print; next}
  {$1 = id[$1 "\t" $2 "\t" $3]; $4 = id[$4 "\t" $5 "\t" $6]; print}' \
  "${prefix}-vars.pvar" "${prefix}.vcor" > "$dir/posid.vcor"
collisions=$(awk -F'\t' -v h="$header_line" 'NR > h {print $3}' "$dir/posid-vars.pvar" | sort | uniq -d | wc -l)
[[ "$collisions" -gt 0 ]] || { echo "ERROR no CHROM:POS collisions in $prefix" >&2; exit 1; }
LDZIP_BUILD_SQL="$PWD/build.sql" ./build.sh "$dir/unique" 262144 9 8 > /dev/null
./build.sh "$dir/posid" 262144 9 8 > /dev/null
unique="$dir/unique-b8-parquet-rg262144-z9/ld.parquet"
posid="$dir/posid-b8-parquet-rg262144-z9/ld.parquet"
"${DUCKDB:-.cache/duckdb}" -bail -noheader -list :memory: <<SQL
SELECT error('CHROM:POS IDs changed the ld table: ' || (SELECT count(*) FROM '$posid') || ' rows, expected ' || (SELECT count(*) FROM '$unique'))
WHERE EXISTS (FROM '$posid' EXCEPT ALL FROM '$unique') OR EXISTS (FROM '$unique' EXCEPT ALL FROM '$posid');
SQL
echo "PASS the ld table is unchanged with $collisions colliding CHROM:POS IDs"
