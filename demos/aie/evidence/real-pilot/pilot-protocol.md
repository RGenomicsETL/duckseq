# Real PBMC parity pilot

Source: 10x Genomics Cell Ranger 3.0.0 `pbmc_1k_v3`, publisher BAM URL in `source-heads.txt`. HEAD reports 4,785,553,644 bytes and byte-range support. The source uses GRCh38 contig names `1`, `10`, etc. HTTP receipts, publisher index, metadata-only initial range and all derivation logs are retained here. The ETag is not a SHA-256 checksum.

Before derivation: limit each derived file to 512 MiB, each process to 180 seconds, and admission to 2 GiB peak RSS. One thread for samtools, DuckDB and Gravlax's Rayon pool. Do not download the entire 4.79 GB BAM for this pilot.

Derive an indexed interval `1:1-3000000`, retaining mapped, nonsupplementary NH=1 records with CB, UB, CR and UR present. This is a restricted real-input compatibility probe, not a full-cohort benchmark and not a performance verdict. Do not drop records because raw/corrected tags differ.

Compare the current SQL's cell/count output with pinned Gravlax on exactly that BAM. Keep raw CR/UR and corrected CB/UB distinct. The single Cell Ranger GEM suffix must be checked before representing its barcode as the 16-base DNA cell identity used by Gravlax; that key-format projection must not change counts or absorb count mismatches. A whitelist derived from the observed corrected CBs is a pilot input, not a chemistry whitelist or validated cell-calling policy. Report its limitation and any disagreements; do not alter data to force parity.

Measure the raw/corrected tag disagreement distribution before interpreting results. A failed real-input admission blocks a performance claim and guides the next bounded compatibility fix.
