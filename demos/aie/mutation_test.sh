#!/usr/bin/env bash
# Require each semantic mutant to disagree with Gravlax, then verify restored SQL.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p work
annotation_backup=$(mktemp)
junction_backup=$(mktemp)
cp sql/annotation_counts.sql "$annotation_backup"
cp sql/junction.sql "$junction_backup"
restore() {
  cp "$annotation_backup" sql/annotation_counts.sql
  cp "$junction_backup" sql/junction.sql
}
cleanup() { restore; rm -f "$annotation_backup" "$junction_backup"; }
trap cleanup EXIT
./test.sh > work/mutation-baseline.log 2>&1

mutate() {
  case "$1" in
    a) perl -0pi -e 's/o\.read_count>u\.read_count OR \(o\.read_count=u\.read_count AND o\.umi<u\.umi\)/o.read_count>u.read_count/' sql/annotation_counts.sql ;;
    b) perl -0pi -e 's/AND \(o\.read_count>u\.read_count OR \(o\.read_count=u\.read_count AND o\.umi<u\.umi\)\)/AND o.umi<u.umi/; s/ORDER BY o\.read_count DESC, o\.umi ASC LIMIT 1/ORDER BY o.umi ASC LIMIT 1/' sql/annotation_counts.sql ;;
    c) perl -0pi -e 's/AND \(o\.read_count>u\.read_count OR \(o\.read_count=u\.read_count AND o\.umi<u\.umi\)\)/AND FALSE/' sql/annotation_counts.sql ;;
    d) perl -0pi -e 's/o\.umi<u\.umi/o.umi>u.umi/; s/o\.umi ASC LIMIT 1/o.umi DESC LIMIT 1/' sql/annotation_counts.sql ;;
    e) perl -0pi -e 's/WHERE \(a.flag & 4\)=0 AND \(a.flag & 2048\)=0/WHERE (a.flag & 4)=0 AND (a.flag & 256)=0 AND (a.flag & 2048)=0/' sql/annotation_counts.sql ;;
    f) perl -0pi -e 's/WHERE \(a.flag & 4\)=0 AND \(a.flag & 2048\)=0/WHERE (a.flag & 4)=0 AND (a.flag & 2048)=0 AND a.nh=1/' sql/annotation_counts.sql ;;
    g) perl -0pi -e "s/count\\(\\*\\) FILTER \\(WHERE op='N'\\)/count(*) FILTER (WHERE op IN ('N','D'))/; s/WHERE p.op IN \\('M','D','=','X'\\)/WHERE p.op IN ('M','=','X')/; s/WHERE t.op='N'/WHERE t.op IN ('N','D')/" sql/annotation_counts.sql ;;
    h) perl -0pi -e "s/'M','D','N','=','X'/'M','D','=','X'/" sql/junction.sql ;;
    i) perl -0pi -e 's/PARTITION BY sample_id,alignment_id/PARTITION BY sample_id,read_id,flag/g' sql/annotation_counts.sql ;;
  esac
}
for mutant in a b c d e f g h i; do
  restore
  mutate "$mutant"
  if cmp -s sql/annotation_counts.sql "$annotation_backup" && cmp -s sql/junction.sql "$junction_backup"; then
    echo "ERROR: mutant $mutant left SQL unchanged" >&2; exit 1
  fi
  log="work/mutant-${mutant}.log"
  if timeout 60s ./test.sh > "$log" 2>&1; then
    echo "FAIL: mutant $mutant survived" >&2; exit 1
  fi
  if grep -Eq '(Parser|Binder|Catalog|Conversion|IO|Internal) Error|command not found|No such file|Segmentation fault' "$log"; then
    echo "ERROR: mutant $mutant failed outside semantic parity; see $log" >&2; exit 1
  fi
  if ! grep -Eq '^FAIL .+: SQL=|^FAIL annotation' "$log"; then
    echo "ERROR: mutant $mutant has no explicit count mismatch; see $log" >&2; exit 1
  fi
  echo "PASS: mutant $mutant disagrees with Gravlax"
  restore
  ./test.sh > "work/restored-${mutant}.log" 2>&1
done
echo 'PASS: all nine mutants fail semantic parity and restored SQL passes'
