#!/usr/bin/env bash
# Materialize a new evidence cache; raw/corrected tag policy is recorded in the cache.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 5 ]]; then
  echo 'usage: prepare_evidence.sh BAM CACHE.duckdb [SAMPLE] [UR|UB] [THREADS]' >&2; exit 2
fi
root=$(cd "$(dirname "$0")" && pwd)
bam=$(realpath "$1")
cache=$(realpath -m "$2")
sample=${3:-sample}
tag=${4:-UR}
threads=${5:-1}
[[ "$tag" == UR || "$tag" == UB ]] || { echo 'UMI tag must be UR or UB' >&2; exit 2; }
[[ "$threads" =~ ^[1-9][0-9]*$ ]] || { echo 'THREADS must be positive' >&2; exit 2; }
[[ -f "$bam" && ! -e "$cache" && ! -e "$cache.wal" ]] || { echo 'Input must exist and output cache must be new' >&2; exit 2; }
duckdb=${DUCKDB:-duckdb}
extension=$(realpath "${DUCKHTS_EXTENSION:-$root/ext/duckhts.duckdb_extension}")
mkdir -p "$(dirname "$cache")"
quote() { printf '%s' "${1//\'/\'\'}"; }
{
  printf "LOAD '%s';\nSET threads=%s;\n" "$(quote "$extension")" "$threads"
  printf "SET memory_limit='%s';\nSET max_temp_directory_size='%s';\n" \
    "$(quote "${AIE_MEMORY_LIMIT:-2GiB}")" "$(quote "${AIE_SPILL_LIMIT:-2GiB}")"
  printf "SET VARIABLE bam_path='%s';\nSET VARIABLE sample_id='%s';\nSET VARIABLE umi_tag='%s';\n" \
    "$(quote "$bam")" "$(quote "$sample")" "$tag"
  printf ".read %s\n" "$root/sql/prepare_evidence.sql"
} | "$duckdb" -unsigned -bail "$cache"
