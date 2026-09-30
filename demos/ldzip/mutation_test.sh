#!/usr/bin/env bash
# Usage: mutation_test.sh [region-prefix]
# Edits build.sql and rebuilds the 8-bit tables; each mutant must fail its check:
# parity_regions.R against LDZip, or allele_key_check.sh for the allele join
# (LDZip requires unique IDs, so parity cannot see that one).
# A mutant that does not change the SQL, or whose build fails, is a harness error.
set -euo pipefail
cd "$(dirname "$0")"
export R_LIBS_USER="$PWD/.rlib:$PWD/.cache/R/library${R_LIBS_USER:+:$R_LIBS_USER}"
prefix=${1:-work/fixture-region/region-mini}
mkdir -p work/perf
mutant_sql=work/perf/mutant.sql
declare -A mutants=(
  [wrong-rounding]='s/CAST(round(CAST(r AS DOUBLE)/CAST(floor(CAST(r AS DOUBLE)/'
  [shifted-index]='s/SELECT a\.idx AS i,/SELECT a.idx + 1 AS i,/'
  [upper-triangle]='s/SELECT j, i, r_q FROM kept WHERE i <> j/SELECT j, i, r_q FROM kept WHERE false/'
  [wrong-threshold]='s/abs(r) >= 0\.0001/abs(r) >= 0.2/'
  [missing-diagonal]='s/WHERE idx NOT IN (SELECT i FROM both_triangles WHERE i = j)/WHERE false/'
  [id-only-join]='s/a\.id = v\.ID_A AND a\.ref = v\.REF_A AND a\.alt = v\.ALT_A/a.id = v.ID_A/; s/b\.id = v\.ID_B AND b\.ref = v\.REF_B AND b\.alt = v\.ALT_B/b.id = v.ID_B/'
)
for mutant in wrong-rounding shifted-index upper-triangle wrong-threshold missing-diagonal id-only-join; do
  sed -e "${mutants[$mutant]}" build.sql > "$mutant_sql"
  if cmp -s build.sql "$mutant_sql"; then
    echo "ERROR mutant did not change build.sql: $mutant" >&2
    exit 1
  fi
  if ! LDZIP_BUILD_SQL="$mutant_sql" ./build.sh "$prefix" 262144 9 8 > "work/perf/mutation-${mutant}.build.log" 2>&1; then
    echo "ERROR mutant build failed instead of reaching its check: $mutant" >&2
    cat "work/perf/mutation-${mutant}.build.log" >&2
    exit 1
  fi
  if [[ "$mutant" == id-only-join ]]; then
    check=(env LDZIP_BUILD_SQL="$PWD/$mutant_sql" ./allele_key_check.sh "$prefix")
  else
    check=(Rscript --vanilla parity_regions.R "$prefix" 8)
  fi
  if "${check[@]}" > "work/perf/mutation-${mutant}.log" 2>&1; then
    echo "FAIL mutant preserved its check: $mutant" >&2
    exit 1
  fi
  echo "PASS $mutant fails: $(grep -m1 -E 'Error' "work/perf/mutation-${mutant}.log" | sed -E 's/^(Invalid Input )?Error: *//')"
done
./build.sh "$prefix" 262144 9 8 > /dev/null
Rscript --vanilla parity_regions.R "$prefix" 8
./allele_key_check.sh "$prefix"
echo "PASS the unmutated build passes both checks again"
