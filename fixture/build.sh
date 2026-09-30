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
  # Abundance chain: X=3, Y=1, Z=1; X-Y and Y-Z are adjacent but X-Z is not.
  for i in 1 2 3; do
    printf '%s\t16\tchr1\t70\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:AAAAAAAAAAAA\tCR:Z:%s\tUR:Z:AAAAAAAAAAAA\tNH:i:1\tHI:i:1\n' "${sample}_chain_x${i}" "$sample" "$barcode" "$barcode" >> "work/${sample}.sam"
  done
  printf '%s\t16\tchr1\t70\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:CAAAAAAAAAAA\tCR:Z:%s\tUR:Z:CAAAAAAAAAAA\tNH:i:1\tHI:i:1\n' "${sample}_chain_y" "$sample" "$barcode" "$barcode" >> "work/${sample}.sam"
  printf '%s\t16\tchr1\t70\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:CCAAAAAAAAAA\tCR:Z:%s\tUR:Z:CCAAAAAAAAAA\tNH:i:1\tHI:i:1\n' "${sample}_chain_z" "$sample" "$barcode" "$barcode" >> "work/${sample}.sam"
  # Tie: P and Q each occur twice; R is one mismatch from each.
  for umi in AAAAAAAAAAAA CCAAAAAAAAAA; do
    for i in 1 2; do
      printf '%s\t0\tchr1\t90\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:%s\tCR:Z:%s\tUR:Z:%s\tNH:i:1\tHI:i:1\n' "${sample}_tie_${umi}_${i}" "$sample" "$barcode" "$umi" "$barcode" "$umi" >> "work/${sample}.sam"
    done
  done
  printf '%s\t0\tchr1\t90\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:ACAAAAAAAAAA\tCR:Z:%s\tUR:Z:ACAAAAAAAAAA\tNH:i:1\tHI:i:1\n' "${sample}_tie_r" "$sample" "$barcode" "$barcode" >> "work/${sample}.sam"
  printf '%s\t0\tchr1\t10\t60\t5M10N5M10N5M\t*\t0\t0\tAAAAAAAAAAAAAAA\tFFFFFFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:TTTTTTTTTTTT\tCR:Z:%s\tUR:Z:TTTTTTTTTTTT\tNH:i:1\tHI:i:1\n' "${sample}_both" "$sample" "$barcode" "$barcode" >> "work/${sample}.sam"
  for label in cross same; do
    if [[ $label == cross ]]; then second=10; umi=GGGGGGGGGGGG; else second=35; umi=TTTTTTTTTTTT; fi
    printf '%s\t0\tchr1\t30\t60\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:%s\tCR:Z:%s\tUR:Z:%s\tNH:i:2\tHI:i:1\n' "${sample}_multi_${label}" "$sample" "$barcode" "$umi" "$barcode" "$umi" >> "work/${sample}.sam"
    printf '%s\t256\tchr1\t%s\t0\t10M\t*\t0\t0\tAAAAAAAAAA\tFFFFFFFFFF\tRG:Z:%s\tCB:Z:%s\tUB:Z:%s\tCR:Z:%s\tUR:Z:%s\tNH:i:2\tHI:i:2\n' "${sample}_multi_${label}" "$second" "$sample" "$barcode" "$umi" "$barcode" "$umi" >> "work/${sample}.sam"
  done
  awk -F '\t' '!/^@/ && NF != 18 { print "SAM field count " NF ": " $0 > "/dev/stderr"; exit 1 }' "work/${sample}.sam"
  samtools view -bS "work/${sample}.sam" | samtools sort -o "$out"
  samtools index "$out"
}
make_bam sample_a AAAAAAAAAAAAAAAA
make_bam sample_b CCCCCCCCCCCCCCCC
cat > fixture/annotation-v1.gtf <<'EOF'
chr1	sqlfixture	exon	10	14	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	25	29	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	30	39	.	+	.	gene_id "geneB"; transcript_id "txB";
chr1	sqlfixture	exon	40	44	.	+	.	gene_id "geneD"; transcript_id "txD";
EOF
cat > fixture/annotation-v2.gtf <<'EOF'
chr1	sqlfixture	exon	10	14	.	+	.	gene_id "geneA"; transcript_id "txA";
chr1	sqlfixture	exon	25	29	.	+	.	gene_id "geneC"; transcript_id "txC";
chr1	sqlfixture	exon	30	39	.	+	.	gene_id "geneB"; transcript_id "txB";
chr1	sqlfixture	exon	40	44	.	+	.	gene_id "geneD"; transcript_id "txD";
EOF
for bam in work/sample_{a,b}.bam; do
  .gravlax/target/release/aie ingest check "$bam" --whitelist fixture/whitelist.txt
  .gravlax/target/release/aie ingest-archive "$bam" --whitelist fixture/whitelist.txt --out "${bam%.bam}.aie" --geometry-fidelity
 done
