#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
cat > fixture/reference.fa <<'EOF'
>chr1
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
EOF
samtools faidx fixture/reference.fa
cat > fixture/whitelist.txt <<'EOF'
AAAAAAAAAAAAAAAA
CCCCCCCCCCCCCCCC
EOF
make_bam() {
  local sample="$1" barcode="$2" out="work/${1}.bam"
  cat > "work/${sample}.sam" <<EOF
@HD	VN:1.6	SO:coordinate
@SQ	SN:chr1	LN:100
@RG	ID:${sample}	SM:${sample}
${sample}_splice	0	chr1	10	60	5M10N5M	*	0	0	AAAAAAAAAA	FFFFFFFFFF	RG:Z:${sample}	CB:Z:${barcode}	UB:Z:AAAAAAAAAAAA	CR:Z:${barcode}	UR:Z:AAAAAAAAAAAA	NH:i:1	HI:i:1
${sample}_deletion	0	chr1	10	60	5M10D5M	*	0	0	AAAAAAAAAA	FFFFFFFFFF	RG:Z:${sample}	CB:Z:${barcode}	UB:Z:CCCCCCCCCCCC	CR:Z:${barcode}	UR:Z:CCCCCCCCCCCC	NH:i:1	HI:i:1
${sample}_splice_rep	0	chr1	10	60	5M10N5M	*	0	0	AAAAAAAAAA	FFFFFFFFFF	RG:Z:${sample}	CB:Z:${barcode}	UB:Z:AAAAAAAAAAAC	CR:Z:${barcode}	UR:Z:AAAAAAAAAAAC	NH:i:1	HI:i:1
${sample}_multi	0	chr1	30	60	10M	*	0	0	AAAAAAAAAA	FFFFFFFFFF	RG:Z:${sample}	CB:Z:${barcode}	UB:Z:GGGGGGGGGGGG	CR:Z:${barcode}	UR:Z:GGGGGGGGGGGG	NH:i:2	HI:i:1
${sample}_multi	256	chr1	60	0	10M	*	0	0	AAAAAAAAAA	FFFFFFFFFF	RG:Z:${sample}	CB:Z:${barcode}	UB:Z:GGGGGGGGGGGG	CR:Z:${barcode}	UR:Z:GGGGGGGGGGGG	NH:i:2	HI:i:2
EOF
  samtools view -bS "work/${sample}.sam" | samtools sort -o "$out"
  samtools index "$out"
}
make_bam sample_a AAAAAAAAAAAAAAAA
make_bam sample_b CCCCCCCCCCCCCCCC
cat > fixture/annotation-v1.gtf <<'EOF'
chr1	sqlfixture	exon	10	14	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	25	29	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	30	39	.	+	.	gene_id "geneB"; transcript_id "txB";
EOF
cat > fixture/annotation-v2.gtf <<'EOF'
chr1	sqlfixture	exon	10	14	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	25	29	.	+	.	gene_id "geneC"; transcript_id "txC";
chr1	sqlfixture	exon	30	39	.	+	.	gene_id "geneB"; transcript_id "txB";
EOF
for bam in work/sample_{a,b}.bam; do
  .gravlax/target/release/aie ingest check "$bam" --whitelist fixture/whitelist.txt
  .gravlax/target/release/aie ingest-archive "$bam" --whitelist fixture/whitelist.txt --out "${bam%.bam}.aie" --geometry-fidelity
 done
