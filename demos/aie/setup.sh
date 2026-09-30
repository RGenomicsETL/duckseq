#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
GRAVLAX_COMMIT=75b8d6c01064ba92af295543d50230429774e170
DUCKDB_VERSION=1.5.1

mkdir -p .cache ext
if [[ -n "${DUCKDB:-}" ]]; then
  duckdb_path=$(command -v "$DUCKDB" 2>/dev/null || printf '%s' "$DUCKDB")
  [[ -x "$duckdb_path" ]] || { echo "DUCKDB is not executable: $DUCKDB" >&2; exit 1; }
else
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux-amd64 ;;
    Linux-aarch64|Linux-arm64) platform=linux-arm64 ;;
    Darwin-arm64) platform=osx-arm64 ;;
    Darwin-x86_64) platform=osx-universal ;;
    *) echo "Unsupported DuckDB CLI platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  duckdb_path="$PWD/.cache/duckdb"
  if [[ ! -x "$duckdb_path" ]]; then
    archive="$PWD/.cache/duckdb_cli.zip"
    curl --fail --location --silent --show-error \
      "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-${platform}.zip" \
      --output "$archive"
    unzip -oq "$archive" -d .cache
    chmod +x "$duckdb_path"
  fi
fi

if [[ -n "${DUCKHTS_EXTENSION:-}" ]]; then
  extension_path=$(realpath "$DUCKHTS_EXTENSION")
  [[ -f "$extension_path" ]] || { echo "DUCKHTS_EXTENSION does not exist: $DUCKHTS_EXTENSION" >&2; exit 1; }
else
  r_lib="$PWD/.cache/R/library"
  mkdir -p "$r_lib"
  R_LIBS_USER="$r_lib" Rscript --vanilla -e '
    lib <- Sys.getenv("R_LIBS_USER")
    if (!requireNamespace("Rduckhts", quietly = TRUE, lib.loc = lib)) {
      install.packages("Rduckhts", repos = "https://rgenomicsetl.r-universe.dev", lib = lib)
    }
  ' > .cache/r-install.log 2>&1 || { cat .cache/r-install.log >&2; exit 1; }
  R_LIBS_USER="$r_lib" Rscript --vanilla -e '
    path <- system.file("duckhts_extension", "build", "duckhts.duckdb_extension", package = "Rduckhts", lib.loc = Sys.getenv("R_LIBS_USER"))
    if (!nzchar(path) || !file.exists(path)) stop("Rduckhts did not provide the DuckHTS extension")
    cat(normalizePath(path))
  ' > .cache/extension-path 2> .cache/r-install.log || { cat .cache/r-install.log >&2; exit 1; }
  extension_path=$(<.cache/extension-path)
fi
ln -sfn "$extension_path" ext/duckhts.duckdb_extension

if [[ ! -d .gravlax/.git ]]; then
  git clone https://github.com/COMBINE-lab/gravlax.git .gravlax
fi
git -C .gravlax checkout --detach "$GRAVLAX_COMMIT"
if [[ ! -x .gravlax/target/release/aie ]]; then
  cargo build --release --manifest-path .gravlax/Cargo.toml
fi

duckdb_version=$("$duckdb_path" --version | head -n 1)
extension_sha=$(sha256sum "$extension_path" | awk '{print $1}')
if [[ -n "${DUCKHTS_EXTENSION:-}" ]]; then
  extension_source="DUCKHTS_EXTENSION override"
else
  extension_source="Rduckhts $(R_LIBS_USER="$PWD/.cache/R/library" Rscript --vanilla -e 'cat(as.character(packageVersion("Rduckhts")))')"
fi
duckhts_library_path="$(dirname "$extension_path")/../htslib/lib"
if [[ ! -d "$duckhts_library_path" ]]; then duckhts_library_path=; else duckhts_library_path=$(realpath "$duckhts_library_path"); fi
cat > EXTENSIONS.txt <<EOF
DuckDB CLI: $duckdb_version
DuckHTS extension source: $extension_source
DuckHTS extension SHA-256: $extension_sha
R package repository: https://rgenomicsetl.r-universe.dev (unless DUCKHTS_EXTENSION is set)
Gravlax commit: $GRAVLAX_COMMIT
Gravlax AIE version: $(.gravlax/target/release/aie --version 2>&1 | head -n 1)
EOF

printf 'export DUCKDB=%q\n' "$duckdb_path"
printf 'export DUCKHTS_EXTENSION=%q\n' "$extension_path"
printf 'export DUCKHTS_LIBRARY_PATH=%q\n' "$duckhts_library_path"
