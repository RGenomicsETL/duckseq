#!/usr/bin/env bash
# Usage: build.sh <region-prefix> [row-group-size] [zstd-level] [bits]
# Reads <prefix>-vars.pvar and <prefix>.vcor and writes
# <prefix>-b<bits>-parquet-rg<rows>-z<level>/{variants,ld}.parquet with the DuckDB CLI.
# LDZIP_BUILD_SQL overrides the SQL file (mutation_test.sh uses this).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:?Usage: build.sh <region-prefix> [row-group-size] [zstd-level] [bits]}
row_group=${2:-262144}
zstd=${3:-9}
bits=${4:-8}
sql=${LDZIP_BUILD_SQL:-$here/build.sql}
duckdb=${DUCKDB:-$here/.cache/duckdb}
case "$bits" in
  8) int_type=TINYINT ;;
  16) int_type=SMALLINT ;;
  *) echo "bits must be 8 or 16" >&2; exit 1 ;;
esac
[[ "$row_group" =~ ^[1-9][0-9]*$ && "$zstd" =~ ^[0-9]+$ ]] || { echo "Invalid Parquet options" >&2; exit 1; }
pvar="${prefix}-vars.pvar"
vcor="${prefix}.vcor"
header_line=$(grep -n -m1 $'^#CHROM\t' "$pvar" | cut -d: -f1)
[[ -n "$header_line" ]] || { echo "PLINK variant file has no #CHROM header" >&2; exit 1; }
out="${prefix}-b${bits}-parquet-rg${row_group}-z${zstd}"
rm -rf "$out"
mkdir -p "$out"
sed -e "s|@PVAR@|$pvar|g" -e "s|@VCOR@|$vcor|g" -e "s|@OUT@|$out|g" \
    -e "s|@PVAR_SKIP@|$((header_line - 1))|g" -e "s|@SCALE@|$(( (1 << (bits - 1)) - 1 ))|g" \
    -e "s|@INT_TYPE@|$int_type|g" -e "s|@ROW_GROUP@|$row_group|g" -e "s|@ZSTD@|$zstd|g" "$sql" |
  "$duckdb" -bail -noheader -list :memory:
echo "PARQUET_DIR=$out"
