# Where: annotation rules and options

How duckpeakwhere's **Where** view reads an annotation and what each optional setting
does. The defaults reproduce Sean Davis's
[peakwhere](https://github.com/seandavi/peakwhere): its hand-worked fixture
(`test/fixtures/expected.json`) holds with every option off.

## Reading the annotation

| Input | Rule |
|---|---|
| GFF3 | Transcripts are the parents of exons (`ID`/`Parent`, percent-decoded, several parents allowed). |
| GTF | A transcript is a `transcript_id` on one chromosome and strand, spanning its `transcript` line or, without one, its exons. GTF 2.2 asks for globally unique ids; UCSC exports reuse them across loci, so copies on other chromosomes stay separate ([peakwhere#27](https://github.com/seandavi/peakwhere/issues/27)). Copies on the same chromosome and strand still merge: some are 41 bp apart, closer than many introns. |
| UTRs | `five_prime_UTR`/`three_prime_UTR` (GFF3), GTF 2.2's `5UTR`/`3UTR` (UCSC), and GENCODE's generic `UTR`, assigned 5′ or 3′ by strand and CDS side. |
| Protein-coding filter | Reads GENCODE's `transcript_type`/`gene_type`, Ensembl's `transcript_biotype`/`gene_biotype` (GTF) or `biotype` (GFF3) ([peakwhere#26](https://github.com/seandavi/peakwhere/issues/26)). A transcript without a type takes its gene line's. With no types at all the filter is skipped, with a warning. |
| Compression | Plain, gzip, multi-member gzip and bgzip, all through htslib ([peakwhere#24](https://github.com/seandavi/peakwhere/issues/24)). |

## Optional settings

All off by default.

| Setting | Rule |
|---|---|
| **Downstream** ([peakwhere#15](https://github.com/seandavi/peakwhere/issues/15)) | A window past each transcript end: after the end on `+`, before the start on `−`, clipped at the chromosome start. Priority Promoter > 5′ UTR > 3′ UTR > Exon > Intron > Downstream > Intergenic, so it only claims otherwise intergenic bases. |
| **narrowPeak summits** ([peakwhere#17](https://github.com/seandavi/peakwhere/issues/17)) | For centre counting only, a narrowPeak's point is `start + peak` (column 10). A missing, negative or out-of-range offset falls back to the midpoint, and the page says how many did. Files are recognised by their `.narrowPeak` name; BED and broadPeak, and base-pair counting, are unchanged. |
| **chrom.sizes** | Two tab-separated columns, name and positive integer length, no header. Selecting the file turns the Genome bar on for annotations without `##sequence-region`; header lengths win when both exist. Names match through `duckhts_contig_key`, only annotated contigs count, and a name listed twice with different lengths is an error. |

Each rule has a hand-worked fixture in `test/fixtures/` with its arithmetic in the file's
comments.
