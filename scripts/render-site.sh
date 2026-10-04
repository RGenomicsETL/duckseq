#!/usr/bin/env bash
# Build the Pages site into a directory (default _site): the landing page and assets
# from site/, the peakwhere app, and the evidence reports rendered with Pandoc.
# Usage: scripts/render-site.sh [output-dir]
# Set SKIP_PEAKWHERE_APP=1 to omit the app when its vendor files are not staged.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-_site}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
if [ ! -f "$out/.duckseq-site" ] && [ -n "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "refusing to clear an unmarked, nonempty directory: $out" >&2
  exit 1
fi
find "$out" -mindepth 1 -delete
touch "$out/.duckseq-site"

repo_url="https://github.com/RGenomicsETL/duckseq"
pandoc_dir="$root/site/pandoc"

# render <report.md> <output route> <repo dir> <title> <scope> <current-page key>
render() {
  local src="$1" route="$2" repo_dir="$3" title="$4" scope="$5" current="$6"
  local depth up
  depth="$(awk -F/ '{print NF}' <<<"$route")"
  up="$(printf '../%.0s' $(seq 1 "$depth"))"
  mkdir -p "$out/$route"
  pandoc "$root/$src" --from=gfm --to=html5 --standalone --no-highlight \
    --template="$pandoc_dir/report.html" --lua-filter="$pandoc_dir/report.lua" \
    --toc --toc-depth=2 --css="${up}assets/site.css" \
    --metadata pagetitle="$title" --metadata-file=/dev/stdin \
    --variable root="$up" --variable "current-$current=true" \
    --variable source-path="$src" --variable source-url="$repo_url/blob/main/$src" \
    --variable scope="$scope" \
    --output="$out/$route/index.html" <<<"repo-dir: $repo_dir
repo-url: $repo_url
site-root: '$up'"
}

cp -r "$root/site/index.html" "$root/site/assets" "$out/"
cp "$root/LICENSE" "$out/LICENSE"

if [ "${SKIP_PEAKWHERE_APP:-0}" != 1 ]; then
  app="$root/demos/peakwhere"
  [ -d "$app/vendor" ] || { echo "demos/peakwhere/vendor is missing; run npm run stage && npm run stage:peek && npm run vendor there, or set SKIP_PEAKWHERE_APP=1" >&2; exit 1; }
  mkdir -p "$out/peakwhere/test"
  cp -r "$app/index.html" "$app/LICENSE" "$app/src" "$app/vendor" "$app/examples" "$app/man" "$out/peakwhere/"
  cp -r "$app/test/fixtures" "$out/peakwhere/test/"
fi

render demos/peakwhere/benchmarks/performance.md peakwhere/performance demos/peakwhere/benchmarks \
  "peakwhere performance" \
  "DuckDB-Wasm and native DuckDB against ChIPseeker on peakwhere's W1 workload (7,220 mouse thymus chr19 peaks) and the larger W2 workload. Local single-machine measurements; not an equal-output speedup claim." \
  peakwhere
render demos/aie/PRODUCT_REPORT.md aie demos/aie \
  "AIE: queryable raw evidence on real PBMC inputs" \
  "Real 1M/2M/4M primary-record BAMs, one/four threads and three fresh processes. SQL raw-UMI labels and overlap families differ from Gravlax classes; these are capability/cost contrasts, not equal-output speedups." \
  aie
render demos/ldzip/REPORT.md ldzip demos/ldzip \
  "LDZip in DuckDB SQL" \
  "Exact 8/16-bit matrices at nested chr20 regions, with six mutation checks and allele-aware keys. Dense extraction and build RSS favour LDZip; pair comparator gaps are documented." \
  ldzip
render demos/ldzip/REVIEW.md ldzip/review demos/ldzip \
  "LDZip performance review" \
  "Verified R matrix-copy and pair-grouping costs, comparator limits, and reproducible diagnostic probes." \
  ldzip-review

render demos/ldzip/NATIVE_REPORT.md ldzip/native demos/ldzip \
  "Native LD matrix measurements" \
  "Three-process, budgeted SQL/TinyCC dense endpoints; native-buffer diagnostics and verified BLAS linkage. Matrix representations differ, and GEMM performance is unmeasured." \
  ldzip

echo "site written to $out"
