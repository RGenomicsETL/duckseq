# Example data

Small, real datasets behind the app's **Mouse thymus** dataset, copied from
[peakwhere](https://github.com/seandavi/peakwhere/tree/main/examples). Everything here is
**chromosome 19 only**, cut down from public mouse data on the **mm10 / GRCm38**
assembly, so the demo loads in a second or two.

| File | What it is | Source |
|---|---|---|
| `gencode.vM25.basic.chr19.gff3.gz` | GENCODE mouse release M25, `basic` transcript set, chr19 lines plus the header and chr19 `##sequence-region` | [GENCODE M25](https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M25/gencode.vM25.basic.annotation.gff3.gz) |
| `thymus_H3K4me3_ENCFF674JZY.chr19.narrowPeak.gz` | H3K4me3 ChIP-seq, 859 peaks | ENCODE [ENCFF674JZY](https://www.encodeproject.org/files/ENCFF674JZY/) / [ENCSR000CCJ](https://www.encodeproject.org/experiments/ENCSR000CCJ/) |
| `thymus_H3K36me3_ENCFF853BYO.chr19.narrowPeak.gz` | H3K36me3 ChIP-seq, 2,855 peaks | ENCODE [ENCFF853BYO](https://www.encodeproject.org/files/ENCFF853BYO/) / [ENCSR000CFV](https://www.encodeproject.org/experiments/ENCSR000CFV/) |
| `thymus_H3K27me3_ENCFF478UYW.chr19.narrowPeak.gz` | H3K27me3 ChIP-seq, 605 peaks | ENCODE [ENCFF478UYW](https://www.encodeproject.org/files/ENCFF478UYW/) / [ENCSR000CGC](https://www.encodeproject.org/experiments/ENCSR000CGC/) |
| `thymus_CTCF_ENCFF714WDP.chr19.narrowPeak.gz` | CTCF ChIP-seq, 706 peaks. ENCODE flags this experiment for *extremely low read depth* | ENCODE [ENCFF714WDP](https://www.encodeproject.org/files/ENCFF714WDP/) / [ENCSR000CDZ](https://www.encodeproject.org/experiments/ENCSR000CDZ/) |
| `thymus_DNase_ENCFF979ULB.chr19.narrowPeak.gz` | DNase-seq, 2,195 peaks | ENCODE [ENCFF979ULB](https://www.encodeproject.org/files/ENCFF979ULB/) / [ENCSR322AIL](https://www.encodeproject.org/experiments/ENCSR322AIL/) |

All peak files are from adult (2-month) male mouse thymus. The four ChIP-seq experiments
are from the Ren lab (ENCODE 2); the DNase-seq is from the Stamatoyannopoulos lab
(ENCODE 4), in a different strain (B6CASTF1/J rather than B6NCrl).

## Regenerating

With the full files downloaded:

```bash
gunzip -c gencode.vM25.basic.annotation.gff3.gz \
  | awk -F'\t' '/^##gff-version/ || /^##sequence-region chr19 / || (!/^#/ && $1=="chr19")' \
  | gzip -9 > gencode.vM25.basic.chr19.gff3.gz

gunzip -c ENCFF674JZY.bed.gz | awk -F'\t' '$1=="chr19"' | sort -k2,2n \
  | gzip -9 > thymus_H3K4me3_ENCFF674JZY.chr19.narrowPeak.gz   # and so on
```

## Citation and terms

GENCODE and ENCODE data are released publicly for unrestricted use. Please cite them if
you use them:

- Frankish A, et al. *GENCODE: reference annotation for the human and mouse genomes.*
  Nucleic Acids Research (2019 and later updates).
- The ENCODE Project Consortium. *Expanded encyclopaedias of DNA elements in the human
  and mouse genomes.* Nature 583, 699–710 (2020). Also cite the individual experiments
  above.
