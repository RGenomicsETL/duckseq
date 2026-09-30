#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
sql=sql/annotation_counts.sql
backup=$(mktemp)
cp "$sql" "$backup"
restore() { cp "$backup" "$sql"; rm -f "$backup"; }
trap restore EXIT HUP INT TERM
survivors=0

run_mutant() {
  local name="$1"
  if ./test.sh >"work/mutation-${name}.log" 2>&1; then
    printf '%s: survived\n' "$name"
    survivors=$((survivors + 1))
    cp "$backup" "$sql"
    ./test.sh >"work/mutation-${name}-restore.log" 2>&1
    cp "$backup" "$sql"
    return 0
  fi
  printf '%s: killed\n' "$name"
  cp "$backup" "$sql"
  if ! ./test.sh >"work/mutation-${name}-restore.log" 2>&1; then
    printf 'Restored SQL failed after mutant %s; see work/mutation-%s-restore.log\n' "$name" "$name" >&2
    return 1
  fi
  cp "$backup" "$sql"
}

# The historical query is an exact checked-in SQL mutant.
git show 6c25368:sql/annotation_counts.sql > "$sql"
run_mutant a

cp "$backup" "$sql"
sed -i 's/AND (o.read_count>u.read_count OR (o.read_count=u.read_count AND o.umi<u.umi))/AND TRUE/; s/ORDER BY o.read_count DESC, o.umi ASC LIMIT 1/ORDER BY o.umi ASC LIMIT 1/' "$sql"
run_mutant b

cp "$backup" "$sql"
sed -i 's/AND (o.read_count>u.read_count OR (o.read_count=u.read_count AND o.umi<u.umi))/AND FALSE/' "$sql"
run_mutant c

cp "$backup" "$sql"
sed -i 's/o.umi<u.umi/o.umi>u.umi/; s/o.umi ASC LIMIT 1/o.umi DESC LIMIT 1/' "$sql"
run_mutant d

cp "$backup" "$sql"
sed -i 's/WHERE (a.flag \& 4)=0 AND (a.flag \& 2048)=0/WHERE (a.flag \& 4)=0 AND (a.flag \& 256)=0 AND (a.flag \& 2048)=0/' "$sql"
run_mutant e

cp "$backup" "$sql"
sed -i 's/WHERE (a.flag \& 4)=0 AND (a.flag \& 2048)=0/WHERE (a.flag \& 4)=0 AND (a.flag \& 2048)=0 AND a.nh=1/' "$sql"
run_mutant f

cp "$backup" "$sql"
sed -i "s/count(\*) FILTER (WHERE op='N')/count(*) FILTER (WHERE op IN ('N','D'))/; s/WHERE p.op IN ('M','D','=','X')/WHERE p.op IN ('M','=','X')/; s/WHERE t.op='N'/WHERE t.op IN ('N','D')/" "$sql"
run_mutant g

cp "$backup" "$sql"
if ! ./test.sh > work/mutation-final.log 2>&1; then
  printf 'Final real SQL failed; see work/mutation-final.log\n' >&2
  exit 1
fi
printf 'real SQL: passed\n'
if (( survivors )); then
  printf '%s mutant(s) survived\n' "$survivors" >&2
  exit 1
fi
