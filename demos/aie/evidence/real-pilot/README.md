# Real PBMC compatibility counterexample

This is a failed admission probe, not a performance benchmark.

## Input and derivation

The public 10x Cell Ranger 3.0.0 `pbmc_1k_v3` BAM is at:

`https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_possorted_genome_bam.bam`

The publisher HEAD response reports 4,785,553,644 bytes and range support. Its multipart ETag is not a SHA-256 checksum. The publisher BAM index and a metadata-only initial 1 MiB range were fetched; the full BAM was not downloaded. HTTP and header receipts are retained.

Derive a complete indexed interval with samtools 1.23:

```bash
url=https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_possorted_genome_bam.bam
curl -fsSL -o source.bam.bai "$url.bai"
samtools view -b -F 2052 \
  -e 'exists([CB]) && exists([UB]) && exists([CR]) && exists([UR]) && [NH] == 1' \
  -o pilot.bam "${url}##idx##$(pwd)/source.bam.bai" '1:1-3000000'
samtools quickcheck -v pilot.bam
```

The resulting BAM has 109,271 records and 7,034,547 bytes. Its observed SHA-256 is `d5d0963915960d3c26cf289434f864d6b3c6b23807a09b23d92fbb26b65de616`. The samtools @PG record includes the derivation path; another host can reproduce the records without obtaining the same header bytes. Runtime/input hashes and predeclared bounds are recorded separately.

This probe restricts mapped, nonsupplementary NH=1 records to a 3 Mb GRCh38 interval with all four tags present. It is not the full cohort. It does not exclude records with unequal raw/corrected tags.

## Result

| Observation | Count |
|---|---:|
| Records with different raw CR and corrected CB barcode | 2,613 |
| Records with different raw UR and corrected UB UMI | 1,124 |
| Cells returned by each implementation | 4,615 |
| Cells with unequal region counts | **653** |
| Gravlax total region count | **42,974** |
| Current SQL total region count | **41,901** |

Both engines receive exactly the derived BAM. `prepare.sql` checks that CB has one GEM group (`DNA16-1`), separates the suffix from the 16-base cell key, and preserves all count differences. The observed corrected barcodes form the explicitly supplied pilot whitelist. This is not a chemistry whitelist or a validated cell-calling policy.

Gravlax ingestion consumes raw CR/UR, while the SQL loader/query uses corrected CB/UB. The synthetic fixture makes these equal. The real-input observations expose that fixture limitation; the counts alone do not isolate every cause of the discrepancy.

`cell-comparison.csv` and `cell-disagreements.csv` preserve complete counts, not rounded/normalized matches. `admission.csv` records `PARITY_FAIL`. Setup errors are retained separately and are not semantic failures. No real-input timing verdict is admitted. This counterexample blocks a broad AIE compatibility or equal-output performance claim until corrected semantics are validated.

## Reproduce the comparison

Use the recorded DuckHTS artifact, pinned Gravlax commit `75b8d6c01064ba92af295543d50230429774e170` and `prepare.sql` to write the pilot relations/whitelist. Set `RAYON_NUM_THREADS=1` and DuckDB `threads=1`.

```bash
aie ingest-archive pilot.bam --whitelist whitelist.txt --out pilot.aie --geometry-fidelity
aie query pilot.aie region 1:1-3000000 --format tsv --top 0 > gravlax-region.tsv
# work/alignments.parquet must point to prepare.sql's alignments.parquet.
duckdb -unsigned -bail -csv -f region.sql > sql-region.csv
Rscript --vanilla compare.R
```

The absolute extension path in `prepare.sql` identifies the measured local artifact; override it explicitly on another host and record the new hash. Exact runtime reproduction is not established by a matching source checkout alone.
