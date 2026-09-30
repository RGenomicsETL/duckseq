
<!-- README.md is generated from README.Rmd with `make readme`. Please edit that file. -->

# duckpeakwhere <img src="man/figures/logo.svg" align="right" height="139" alt="duckpeakwhere hex sticker" />

[![test](https://github.com/sounkou-bioinfo/duckpeakwhere/actions/workflows/test.yml/badge.svg)](https://github.com/sounkou-bioinfo/duckpeakwhere/actions/workflows/test.yml)
[![pages](https://github.com/sounkou-bioinfo/duckpeakwhere/actions/workflows/pages.yml/badge.svg)](https://github.com/sounkou-bioinfo/duckpeakwhere/actions/workflows/pages.yml)

**Genomics tools as SQL, in the browser.** duckpeakwhere answers two
first questions about a peak set (where do the peaks land, and what is
in these files) with no parser, no interval engine and no server of its
own. [htslib](https://github.com/samtools/htslib) reads the formats,
[DuckHTS](https://github.com/RGenomicsETL/duckhts) supplies the interval
kernels, and [DuckDB](https://duckdb.org) does everything else, running
as [duckdb-wasm](https://github.com/duckdb/duckdb-wasm) in your tab.

**Try it: <https://sounkou-bioinfo.github.io/duckpeakwhere/>**. Files
never leave your computer, and the page makes no requests outside its
own origin.

It is a port of two tools by Sean Davis,
[peakwhere](https://github.com/seandavi/peakwhere) and
[PeakPeek](https://github.com/seandavi/peakpeek), keeping their rules
and their hand-worked answers and replacing their JavaScript parsers and
algorithms with SQL.

## Two views

- **Where** splits ChIP-seq, CUT&RUN or ATAC-seq peaks into promoter, 5′
  UTR, 3′ UTR, exon, intron and intergenic space against a GFF3/GTF
  annotation, by peak centre or by base pair, next to a genome
  background bar.
- **Peek** summarises peak files with no annotation: widths, merged
  coverage, chromosomes, duplicates, overlaps and problems, side by
  side.

Both take BED, narrowPeak and broadPeak files, plain, gzip or bgzip, and
share one file selection, one database and one set of validity rules.

## How it works

| Step                                                                | Upstream (JavaScript)          | Here                                                    |
|---------------------------------------------------------------------|--------------------------------|---------------------------------------------------------|
| Read GFF3 / GTF / BED                                               | hand-written streaming parsers | `read_gff`, `read_gtf`, `read_bed` (htslib)             |
| Match `chr1` with `1`, `chrM` with `MT`                             | string rules                   | `duckhts_contig_key`                                    |
| Transcripts, UTRs, promoter windows                                 | object model                   | SQL over the feature table                              |
| Priority partition (Promoter \> 5′ UTR \> 3′ UTR \> Exon \> Intron) | sorted segments                | cut points in SQL, labelled by a DuckHTS cgranges index |
| Peak centres, base pairs, coverage, overlaps                        | binary search, sweeps          | cgranges probes and SQL aggregation                     |

The SQL is in [`src/annotate.js`](src/annotate.js) (Where),
[`src/peek.js`](src/peek.js) (Peek) and [`src/peaks.js`](src/peaks.js)
(shared peak ingestion). Tables are cached for the session, so changing
a setting re-counts rather than re-reads.

## Try the SQL

The tables behind each run stay live. Open the **SQL console** under the
results and query them, or call DuckHTS on your files directly. Each
example chip replays one finding: Ensembl biotypes, a transcript_id
reused across chromosomes, GTF 2.2’s UTR names, a multi-member gzip read
to its last row.

``` sql
-- The genome partition, straight from the cut points.
SELECT priority, count(*) AS pieces, sum(e - s) AS bp
FROM segment GROUP BY priority ORDER BY priority;
```

``` sql
-- What the protein-coding filter sees, whichever naming the annotation uses.
SELECT biotype, count(*) AS transcripts
FROM tx GROUP BY biotype ORDER BY transcripts DESC;
```

**Show the SQL** under each result lists every statement that run
executed, in order.

## The same SQL, outside the browser

Nothing in it is browser-specific. These chunks run in the DuckDB CLI
with the same DuckHTS extension, on the bundled example data.

``` sql
SELECT feature, count(*) AS n
FROM read_gff('examples/gencode.vM25.basic.chr19.gff3.gz', scan_mode := 'sequential')
GROUP BY feature
ORDER BY n DESC, feature
LIMIT 6;
#> ┌─────────────────┬───────┐
#> │     feature     │   n   │
#> │     varchar     │ int64 │
#> ├─────────────────┼───────┤
#> │ exon            │ 17082 │
#> │ CDS             │ 14404 │
#> │ five_prime_UTR  │  2429 │
#> │ transcript      │  2303 │
#> │ three_prime_UTR │  1577 │
#> │ start_codon     │  1553 │
#> └─────────────────┴───────┘
```

``` sql
SELECT 'CTCF' AS mark, count(*) AS peaks, median("end" - start) AS median_width
FROM read_bed('examples/thymus_CTCF_ENCFF714WDP.chr19.narrowPeak.gz', scan_mode := 'sequential')
UNION ALL
SELECT 'H3K4me3', count(*), median("end" - start)
FROM read_bed('examples/thymus_H3K4me3_ENCFF674JZY.chr19.narrowPeak.gz', scan_mode := 'sequential');
#> ┌─────────┬───────┬──────────────┐
#> │  mark   │ peaks │ median_width │
#> │ varchar │ int64 │    double    │
#> ├─────────┼───────┼──────────────┤
#> │ CTCF    │   706 │        344.0 │
#> │ H3K4me3 │   859 │        648.0 │
#> └─────────┴───────┴──────────────┘
```

``` sql
SELECT duckhts_contig_key('chr19') = duckhts_contig_key('19') AS same_contig,
       duckhts_contig_key('chrM') = duckhts_contig_key('MT') AS same_mito;
#> ┌─────────────┬───────────┐
#> │ same_contig │ same_mito │
#> │   boolean   │  boolean  │
#> ├─────────────┼───────────┤
#> │ true        │ true      │
#> └─────────────┴───────────┘
```

## Is it right?

Every number is checked against answers that share no code with the SQL:

- **Where** reproduces peakwhere’s hand-worked fixture, and the mouse
  thymus chr19 example below matches [`test/oracle.R`](test/oracle.R), a
  brute-force base-R version.
- On the full genome (all of GENCODE M25 and five whole ENCODE files),
  all 30 category counts are **identical to upstream peakwhere**.
- **Peek** reproduces PeakPeek’s hand-worked fixture and its published
  full-file results for the same five ENCODE files.

|          | promoter | utr5 | utr3 | exon | intron | intergenic |
|:---------|---------:|-----:|-----:|-----:|-------:|-----------:|
| CTCF     |      360 |    0 |   15 |   28 |    192 |        111 |
| DNase    |      893 |    1 |   47 |   60 |    732 |        462 |
| H3K27me3 |      233 |    1 |   13 |   29 |    148 |        181 |
| H3K36me3 |       96 |    5 |  226 |  440 |   2007 |         81 |
| H3K4me3  |      594 |    1 |    8 |   30 |    148 |         78 |

## How fast?

Same machine and browser, same full-genome inputs, median seconds of
five runs ([`benchmarks/head-to-head.md`](benchmarks/head-to-head.md)):

| step                          | upstream peakwhere | duckpeakwhere |
|:------------------------------|-------------------:|--------------:|
| First analysis                |               4.35 |          6.06 |
| Redraw: centres to base pairs |               0.53 |          0.29 |
| Redraw: promoter window       |               0.49 |          1.81 |

Upstream’s redraws include a 300 ms debounce. The remaining first-run
gap is in attribute parsing, and is being closed in DuckHTS rather than
here
([\#11](https://github.com/sounkou-bioinfo/duckpeakwhere/issues/11),
[duckhts#249](https://github.com/RGenomicsETL/duckhts/issues/249)).

## Your own files

Choose **Local files** and pick or drop an annotation and peak files.
They are read in place through `blob:` URLs, never uploaded.

An annotation without `##sequence-region` lines (every GTF) has no
Genome bar; add a chrom.sizes file to get one. The optional Where
settings (Downstream, narrowPeak summits, chrom.sizes) and their exact
rules are in [`docs/where.md`](docs/where.md).

Reading `blob:` URLs needs a DuckHTS release that includes it (merged,
not yet released). Until then the page says so, and `?duckhts=dev` loads
a pinned development build of DuckHTS that can.

## Limitations

- Peak files must be BED-family; CSV/TSV tables are not read yet
  ([duckhts#250](https://github.com/RGenomicsETL/duckhts/issues/250)
  covers malformed rows too). Details for Peek are in
  [`docs/peakpeek.md`](docs/peakpeek.md).
- The page needs a DuckDB 1.5 runtime of duckdb-wasm
  ([duckhts#247](https://github.com/RGenomicsETL/duckhts/issues/247)).
- Editable bar labels are not available.

## Development

``` bash
npm ci
npm run stage && npm run stage:peek && npm run vendor
npm run serve    # http://127.0.0.1:8000/
npm test         # headless Chromium
```

Every downloaded file (DuckHTS builds, example data) is pinned and
checked against a SHA-256 manifest. `make readme` renders this file from
`README.Rmd`; `make head-to-head` renders the benchmark. House rules for
contributors and agents are in [`AGENTS.md`](AGENTS.md).

Example data comes from GENCODE and ENCODE
([`examples/README.md`](examples/README.md)). peakwhere and PeakPeek are
by **Sean Davis**; their rules and hand-worked fixtures are used here
under MIT. See [`LICENSE`](LICENSE).
