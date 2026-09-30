#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
LDZIP_COMMIT=f8e363af03b2101b04e56b142595a16a060856b6
PLINK_VERSION=v2.0.0-a.7.10
PLINK_SHA256=671e8d707060ff141ad577a31fc71ef43b96f4dde1ce6e042ebaf27f39c02cc3
DUCKDB_VERSION=1.5.5
DUCKDB_SHA256=08c0ca117111fcede14239d0093792352befdc174218c344d232c13279643d05
NO_DATA=0
if [[ "${1:-}" == "--no-data" ]]; then NO_DATA=1; fi
CHR20_SHA256=c2624c726c6cb27e288fe5908621125740379a3d523299dd07c13abf97645e4b

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
mkdir -p .cache .rlib work/input work/derived ext
if [[ ! -d .ldzip/.git ]]; then
  git clone https://github.com/23andMe/LDZip.git .ldzip
fi
git -C .ldzip checkout --detach "$LDZIP_COMMIT"
make -C .ldzip/cpp -j"$(nproc)" build
Rscript --vanilla -e 'Rcpp::compileAttributes(".ldzip/R")'
R CMD INSTALL --library="$PWD/.rlib" .ldzip/R

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) plink_asset=plink2_linux_x86_64.zip ;;
  *) echo "Pinned PLINK binary is defined for Linux x86_64" >&2; exit 1 ;;
esac
if [[ -n "$plink_asset" ]]; then
  archive=".cache/$plink_asset"
  if [[ ! -f "$archive" ]] || [[ "$(sha256_file "$archive")" != "$PLINK_SHA256" ]]; then
    curl --fail --location --retry 3 "https://github.com/chrchang/plink-ng/releases/download/$PLINK_VERSION/$plink_asset" --output "$archive"
  fi
  echo "$PLINK_SHA256  $archive" | sha256sum --check
  unzip -oq "$archive" -d .cache/plink2
  mv .cache/plink2/plink2 .cache/plink2-bin
  rm -rf .cache/plink2
  chmod +x .cache/plink2-bin
  .cache/plink2-bin --version | head -n 1 | tee .cache/plink2.version
fi

if [[ -n "${DUCKDB:-}" ]]; then
  duckdb_path=$(command -v "$DUCKDB" 2>/dev/null || printf '%s' "$DUCKDB")
  [[ -x "$duckdb_path" ]] || { echo "DUCKDB is not executable: $DUCKDB" >&2; exit 1; }
else
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux-amd64 ;;
    Linux-aarch64|Linux-arm64) platform=linux-arm64 ;;
    *) echo "Unsupported DuckDB CLI platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  duckdb_path="$PWD/.cache/duckdb"
  if [[ ! -x "$duckdb_path" ]] || [[ "$("$duckdb_path" --version | awk '{print $1}')" != "v${DUCKDB_VERSION}" ]]; then
    curl --fail --location --retry 3 "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-${platform}.zip" --output .cache/duckdb_cli.zip
    echo "$DUCKDB_SHA256  .cache/duckdb_cli.zip" | sha256sum --check
    unzip -oq .cache/duckdb_cli.zip -d .cache
    chmod +x "$duckdb_path"
  fi
fi

# Match demos/aie's R-universe installation path while suppressing bspm's apt hook.
r_lib="$PWD/.cache/R/library"
mkdir -p "$r_lib"
R_LIBS_USER="$r_lib" Rscript --vanilla -e '
  if (requireNamespace("bspm", quietly=TRUE)) bspm::disable()
  if (!requireNamespace("Rduckhts", quietly=TRUE)) install.packages("Rduckhts", repos="https://rgenomicsetl.r-universe.dev")
' > .cache/rduckhts-install.log 2>&1 || { cat .cache/rduckhts-install.log >&2; exit 1; }
R_LIBS_USER="$r_lib" Rscript --vanilla -e '
  if (!requireNamespace("duckdb", quietly=TRUE) || as.character(packageVersion("duckdb")) != "1.5.5") {
    if (requireNamespace("bspm", quietly=TRUE)) bspm::disable()
    install.packages("duckdb", repos="https://cloud.r-project.org", lib=Sys.getenv("R_LIBS_USER"))
  }
  stopifnot(as.character(packageVersion("duckdb")) == "1.5.5")
' > .cache/duckdb-r-install.log 2>&1 || { cat .cache/duckdb-r-install.log >&2; exit 1; }
extension_path=$(R_LIBS_USER="$r_lib" Rscript --vanilla -e 'cat(system.file("duckhts_extension", "build", "duckhts.duckdb_extension", package="Rduckhts"))')
[[ -f "$extension_path" ]] || { echo "Rduckhts did not provide DuckHTS extension" >&2; exit 1; }
ln -sfn "$extension_path" ext/duckhts.duckdb_extension

cat > .cache/versions.txt <<EOF
LDZip commit: $LDZIP_COMMIT
$(.cache/plink2-bin --version | head -n 1 2>/dev/null || true)
PLINK SHA-256: $PLINK_SHA256
DuckDB: $("$duckdb_path" --version | head -n 1)
DuckDB CLI SHA-256: $DUCKDB_SHA256
DuckHTS extension SHA-256: $(sha256_file "$extension_path")
EOF
printf 'export DUCKDB=%q\nexport DUCKHTS_EXTENSION=%q\nexport PLINK2=%q\nexport LDZIP=%q\nexport R_LIBS_USER=%q\n' \
  "$duckdb_path" "$PWD/ext/duckhts.duckdb_extension" "${PWD}/.cache/plink2-bin" "$PWD/.ldzip/cpp/bin/ldzip" "$PWD/.rlib"

if (( NO_DATA )); then exit 0; fi
if [[ ! -s work/input/chr20.vcf.gz ]]; then
  curl --fail --location --retry 3 \
    'https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20201028_3202_phased/CCDG_14151_B01_GRM_WGS_2020-08-05_chr20.filtered.shapeit2-duohmm-phased.vcf.gz' \
    --output work/input/chr20.vcf.gz
fi
echo "$CHR20_SHA256  work/input/chr20.vcf.gz" | sha256sum --check
if [[ ! -s work/input/samples.panel ]]; then
  curl --fail --location --retry 3 \
    'https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/integrated_call_samples_v3.20130502.ALL.panel' \
    --output work/input/samples.panel
fi
echo 'b4023dc6ee2d62ee89c8d4d347db4d348e65518d66d346574cdae7a4bbd76858  work/input/samples.panel' | sha256sum --check
