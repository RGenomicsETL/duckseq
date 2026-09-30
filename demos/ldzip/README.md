# LDZip in DuckDB SQL

This demo compares LDZip's compressed sparse LD matrices and SQLite variant index with sorted Parquet tables queried by DuckDB. LDZip is checked out at `f8e363af03b2101b04e56b142595a16a060856b6`; downloaded tools and data are kept under ignored paths.

## Reproduce

Requirements: Linux x86-64, R with a C++ toolchain, `make`, `curl`, `unzip`, DuckDB-compatible disk space, and about 50 GB free for the chromosome 20 source and derived benchmark data.

```sh
cd demos/ldzip
./setup.sh
./test.sh
./run_regions.sh
```

After preparing the source input, `./full_test.sh` runs the entire 1×/2×/4× parity and mutation suite. `./measure_build.sh` and `./measure_queries.sh` perform the three-process performance runs.

`setup.sh` builds LDZip and installs `LDZipMatrix` into `.rlib/`, downloads the pinned PLINK 2 binary, DuckDB CLI, and DuckHTS extension, and verifies the source VCF and 1000 Genomes sample panel against `checksums.txt`. Use `./setup.sh --no-data` for the CI-sized fixture tests. `R CMD INSTALL` avoids the host's unrelated bspm/apt-key failure.

The tutorial input is [the phased 1000 Genomes high-coverage chr20 VCF](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20201028_3202_phased/CCDG_14151_B01_GRM_WGS_2020-08-05_chr20.filtered.shapeit2-duohmm-phased.vcf.gz) and the [20130502 population panel](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/integrated_call_samples_v3.20130502.ALL.panel). Their SHA-256 values are recorded in `checksums.txt`. The PLINK 2 archive is the `plink2_linux_x86_64.zip` asset from release `v2.0.0-a.7.10` of [plink-ng](https://github.com/chrchang/plink-ng/releases/tag/v2.0.0-a.7.10); the DuckDB CLI archive is the `duckdb_cli-linux-amd64.zip` asset from release `v1.5.5`.

`run_regions.sh` uses nested chr20 spans of 250 kb, 500 kb, and 1 Mb, beginning at 20 Mb. It filters to the tutorial's EUR panel and uses PLINK 2 `--ld-window-kb 1000 --ld-window-r2 0.01 --r-unphased ref-based cols=id,ref,alt`. Both LDZip bit depths and sorted Parquet outputs are built. All derived files stay in `work/`.

The detailed evidence, known limits, and reproduction commands are in [REPORT.md](REPORT.md). `parity_regions.R` validates each scaled region; `mutation_test.sh` checks the five specified failure modes on small discriminating examples.
