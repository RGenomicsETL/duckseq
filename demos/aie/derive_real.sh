#!/usr/bin/env bash
# Exact nested prefixes of genuine primary records; no read/barcode replication.
set -euo pipefail
[[ $# -eq 2 ]] || { echo 'usage: derive_real.sh SOURCE.bam NEW_OUTPUT_DIR' >&2; exit 2; }
source=$(realpath "$1")
out=$(realpath -m "$2")
[[ ! -e "$out" ]] || { echo 'Output directory must be new' >&2; exit 2; }
mkdir -p "$out"
cd "$out"
export OMP_NUM_THREADS=1
ulimit -f 2097152
samtools view --no-PG -h -F 2308 \
  -e 'exists([CB]) && exists([UB]) && exists([CR]) && exists([UR]) && [NH] == 1' "$source" |
awk '
BEGIN {
  for (i=1;i<=3;i++) {
    limit[i]=1000000*2^(i-1)
    command[i]=sprintf("samtools view --no-PG -b -o n%d.bam -",limit[i])
  }
}
/^@/ { for(i=1;i<=3;i++) print | command[i]; next }
{ n++; for(i=1;i<=3;i++) if(n<=limit[i]) print | command[i] }
END {
  for(i=1;i<=3;i++) if(close(command[i])!=0) exit 1
  if(n<4000000) { print "Source has too few eligible records" > "/dev/stderr"; exit 1 }
  print n > "source-eligible-count.txt"
}'
for n in 1000000 2000000 4000000; do
  samtools quickcheck -v "$out/n$n.bam"
  count=$(samtools view -c "$out/n$n.bam")
  [[ "$count" -eq "$n" ]] || { echo "Record-count mismatch for $n" >&2; exit 1; }
  sha256sum "$out/n$n.bam"
done > "$out/SHA256SUMS"
