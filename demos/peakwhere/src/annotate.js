// Peak annotation as SQL over DuckHTS. htslib reads the files (read_gff, read_gtf,
// read_bed), plain SQL derives the category intervals, and DuckHTS's cgranges index
// resolves them into one priority partition that every count is taken from.
//
// Coordinates are 0-based half-open throughout; read_gff/read_gtf report GFF's 1-based
// closed `start`, so `start - 1` is the only base change.
//
// Every file is read whole, so readers use scan_mode := 'sequential': htslib streams the
// file without probing for a .tbi/.csi index, which in the browser would be wasted
// same-origin requests.

import { readPeaks, peakWarnings } from "./peaks.js";

export const CATEGORIES = ["promoter", "utr5", "utr3", "exon", "intron", "downstream", "intergenic"];

export const categoriesFor = (settings) => CATEGORIES.filter((c) => c !== "downstream" || settings.downstreamEnabled);

export const CATEGORY_LABELS = {
  promoter: "Promoter",
  utr5: "5′ UTR",
  utr3: "3′ UTR",
  exon: "Exon",
  intron: "Intron",
  downstream: "Downstream",
  intergenic: "Intergenic",
};

export const DEFAULT_SETTINGS = Object.freeze({
  promoterUpstream: 1000,
  promoterDownstream: 1000,
  mode: "centre", // "centre" | "bp"
  proteinCodingOnly: false,
  downstreamEnabled: false,
  downstreamWindow: 1000,
  useSummits: false,
});

/** A file with more than this fraction of unmatched peaks is not drawn. */
export const MAX_UNMATCHED_FRACTION = 0.05;

/** Priority of each category: the index in CATEGORIES, 1-based. Intergenic is never indexed. */
const PRIORITY = Object.fromEntries(CATEGORIES.map((c, i) => [c, i + 1]));

// Type attribute keys: GENCODE's names, then Ensembl's (*_biotype in GTF, biotype in GFF3).
// GFF3's one biotype key reads as gene_type, which every transcript falls back to.
const TRANSCRIPT_TYPE = "(?:transcript_type|transcript_biotype)";
const GENE_TYPE = "(?:gene_type|gene_biotype|biotype)";

const ASSEMBLY = /\b(GRC[hm]\d+|mm\d+|hg\d+)\b/;

let runCounter = 0;

/** SQL string literal. */
function lit(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function nonNegativeInt(value, name) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${name} must be a whole number ≥ 0, got ${value}`);
  return n;
}

/** GFF3 or GTF, from `##gff-version 3` or the original filename (blob URLs have no suffix). */
function annotationFormat(url, headerLines) {
  if (headerLines.some((l) => /^##gff-version\s+3\b/.test(l))) return "gff3";
  if (/\.gtf(\.gz)?$/i.test(url)) return "gtf";
  return "gff3";
}

/**
 * Normalise GFF3 or GTF features into two tables:
 *   part(tx, ckey, s, e, strand, kind)  kind ∈ exon, cds, utr5, utr3, utr
 *   tx(tx, ckey, s, e, strand, biotype) one row per transcript that has an exon
 * A GFF3 transcript is any feature that is the Parent of an exon; a GTF transcript is a
 * transcript_id on one chromosome and strand, spanning its transcript line or, without
 * one, its exons.
 */
function featureSql(format, url) {
  const reader = format === "gtf" ? "read_gtf" : "read_gff";
  const kind = `CASE lower(feature)
      WHEN 'exon' THEN 'exon' WHEN 'cds' THEN 'cds'
      WHEN 'five_prime_utr' THEN 'utr5' WHEN 'three_prime_utr' THEN 'utr3'
      WHEN '5utr' THEN 'utr5' WHEN '3utr' THEN 'utr3'
      WHEN 'utr' THEN 'utr' END`;
  // Attributes are extracted per key and only on the rows that use that key, rather
  // than parsing every row into a MAP: on GENCODE the MAP cost ~8 of ~9 s natively.
  const attr = (key) => format === "gtf"
    ? `nullif(regexp_extract(attributes, '(?:^|;)\\s*${key}\\s+"([^"]*)"', 1), '')`
    : `nullif(regexp_extract(attributes, '(?:^|;)\\s*${key}=([^;]*)', 1), '')`;

  if (format === "gtf") {
    // GTF links transcripts and exon spans to gene lines by gene_id.
    // A transcript is a transcript_id on one chromosome and strand: some GTFs (UCSC's)
    // reuse an id for copies at other loci, which must not merge into one span.
    const tx = "transcript_id || chr(31) || ckey || strand";
    return `
CREATE OR REPLACE TEMP TABLE feature AS
SELECT * EXCLUDE (attributes),
       CASE WHEN type = 'gene' OR ((kind = 'exon' OR type = 'transcript')
         AND transcript_type IS NULL AND gene_type IS NULL) THEN ${attr("gene_id")} END AS gene_id
FROM (
  SELECT seqname, ckey, s, e, strand, type, kind, attributes,
         CASE WHEN kind IS NOT NULL OR type = 'transcript' THEN ${attr("transcript_id")} END AS transcript_id,
         CASE WHEN kind = 'exon' OR type = 'transcript' THEN ${attr(TRANSCRIPT_TYPE)} END AS transcript_type,
         CASE WHEN kind = 'exon' OR type IN ('transcript', 'gene') THEN ${attr(GENE_TYPE)} END AS gene_type
  FROM (SELECT seqname, duckhts_contig_key(seqname) AS ckey, start - 1 AS s, "end" AS e, strand,
               lower(feature) AS type, ${kind} AS kind, attributes
        FROM ${reader}(${lit(url)}, scan_mode := 'sequential')));
CREATE OR REPLACE TEMP TABLE part AS
SELECT ${tx} AS tx, ckey, s, e, strand, kind
FROM feature WHERE kind IS NOT NULL AND transcript_id IS NOT NULL;
CREATE OR REPLACE TEMP TABLE tx AS
WITH exon_span AS (
  SELECT ${tx} AS tx, ckey, strand, min(s) AS s, max(e) AS e,
         any_value(gene_id) AS gene_id, any_value(coalesce(transcript_type, gene_type)) AS biotype
  FROM feature WHERE kind = 'exon' AND transcript_id IS NOT NULL GROUP BY ALL
), line AS (
  SELECT ${tx} AS tx, any_value(s) AS s, any_value(e) AS e,
         any_value(gene_id) AS gene_id, any_value(coalesce(transcript_type, gene_type)) AS biotype
  FROM feature WHERE type = 'transcript' GROUP BY 1
), gene AS (
  SELECT gene_id, ckey, strand, any_value(gene_type) AS biotype
  FROM feature WHERE type = 'gene' AND gene_id IS NOT NULL GROUP BY ALL
)
SELECT x.tx, x.ckey, coalesce(l.s, x.s) AS s, coalesce(l.e, x.e) AS e, x.strand,
       coalesce(l.biotype, x.biotype, g.biotype) AS biotype
FROM exon_span x LEFT JOIN line l USING (tx)
LEFT JOIN gene g ON g.gene_id = coalesce(l.gene_id, x.gene_id)
  AND g.ckey = x.ckey AND g.strand = x.strand;`;
  }

  // GFF3 links by ID/Parent. Parts (exon, CDS, UTR) need only Parent. Transcripts and
  // genes are among the non-part rows, which also carry ID and the type keys.
  return `
CREATE OR REPLACE TEMP TABLE feature AS
SELECT seqname, ckey, s, e, strand, type, kind,
       ${attr("Parent")} AS parent,
       CASE WHEN kind IS NULL THEN ${attr("ID")} END AS id,
       CASE WHEN kind IS NULL THEN ${attr(TRANSCRIPT_TYPE)} END AS transcript_type,
       CASE WHEN kind IS NULL THEN ${attr(GENE_TYPE)} END AS gene_type
FROM (SELECT seqname, duckhts_contig_key(seqname) AS ckey, start - 1 AS s, "end" AS e, strand,
             lower(feature) AS type, ${kind} AS kind, attributes
      FROM ${reader}(${lit(url)}, scan_mode := 'sequential'));
CREATE OR REPLACE TEMP TABLE part AS
SELECT CASE WHEN contains(t, '%') THEN url_decode(t) ELSE t END AS tx, ckey, s, e, strand, kind
FROM (SELECT trim(p.tx) AS t, ckey, s, e, strand, kind
      FROM feature, unnest(string_split(parent, ',')) AS p(tx)
      WHERE kind IS NOT NULL);
CREATE OR REPLACE TEMP TABLE tx AS
WITH id AS (
  SELECT url_decode(id) AS id, ckey, s, e, strand, parent, transcript_type, gene_type
  FROM feature WHERE id IS NOT NULL
)
SELECT t.id AS tx, t.ckey, t.s, t.e, t.strand,
       coalesce(t.transcript_type, t.gene_type, g.gene_type) AS biotype
FROM id t
LEFT JOIN id g ON g.id = url_decode(t.parent)
WHERE t.id IN (SELECT tx FROM part WHERE kind = 'exon');`;
}

/**
 * Category intervals, one row per (ckey, s, e, priority). Intron is the transcript span
 * at intron priority: every exonic base of the transcript is already claimed by a
 * higher-priority exon, UTR or promoter interval, so what's left of the span is intron.
 */
function categorySql({ promoterUpstream: up, promoterDownstream: down, proteinCodingOnly,
  downstreamEnabled, downstreamWindow }) {
  const txFilter = proteinCodingOnly ? "WHERE biotype = 'protein_coding'" : "";
  return `
CREATE OR REPLACE TEMP TABLE used_tx AS SELECT * FROM tx ${txFilter};
CREATE OR REPLACE TEMP TABLE category_interval AS
WITH p AS (SELECT part.* FROM part SEMI JOIN used_tx USING (tx)),
cds AS (SELECT tx, min(s) AS cds_s, max(e) AS cds_e FROM p WHERE kind = 'cds' GROUP BY tx),
utr AS (
  -- GTF's generic UTR becomes 5' or 3' by which side of the CDS it lies on.
  SELECT p.ckey, p.s, p.e,
    CASE WHEN p.kind <> 'utr' THEN p.kind
         WHEN (p.strand = '-') = (p.s >= cds.cds_e) THEN 'utr5'
         ELSE 'utr3' END AS kind
  FROM p LEFT JOIN cds USING (tx)
  WHERE p.kind IN ('utr5', 'utr3') OR (p.kind = 'utr' AND cds.tx IS NOT NULL)
),
tss AS (SELECT ckey, strand, CASE WHEN strand = '-' THEN e - 1 ELSE s END AS t FROM used_tx)
SELECT ckey,
       greatest(0, CASE WHEN strand = '-' THEN t - ${down} ELSE t - ${up} END) AS s,
       CASE WHEN strand = '-' THEN t + ${up} + 1 ELSE t + ${down} + 1 END AS e,
       ${PRIORITY.promoter} AS priority
FROM tss
UNION ALL
SELECT ckey, s, e, CASE kind WHEN 'utr5' THEN ${PRIORITY.utr5} ELSE ${PRIORITY.utr3} END FROM utr
UNION ALL
SELECT ckey, s, e, ${PRIORITY.exon} FROM p WHERE kind = 'exon'
UNION ALL
SELECT ckey, s, e, ${PRIORITY.intron} FROM used_tx
${downstreamEnabled && downstreamWindow > 0 ? `UNION ALL
SELECT ckey,
       CASE WHEN strand = '-' THEN greatest(0, s - ${downstreamWindow}) ELSE e END,
       CASE WHEN strand = '-' THEN s ELSE e + ${downstreamWindow} END,
       ${PRIORITY.downstream}
FROM used_tx WHERE strand <> '-' OR s > 0` : ""};`;
}

/**
 * The priority partition: cut each chromosome at every interval end, and give each
 * elementary segment the best priority among the category intervals cgranges finds over
 * it. Segments no interval covers are intergenic and are left out.
 */
function partitionSql(categoryIndex, partitionIndex) {
  return [
    `SELECT duckhts_cgranges_create(${lit(categoryIndex)})`,
    `SELECT bool_and(duckhts_cgranges_add(${lit(categoryIndex)}, ckey, s, e, priority)) FROM category_interval`,
    `SELECT duckhts_cgranges_index(${lit(categoryIndex)})`,
    `CREATE OR REPLACE TEMP TABLE segment AS
WITH cut AS (
  SELECT DISTINCT ckey, x FROM (
    SELECT ckey, s AS x FROM category_interval UNION ALL SELECT ckey, e FROM category_interval)
), piece AS (
  SELECT ckey, x AS s, lead(x) OVER (PARTITION BY ckey ORDER BY x) AS e FROM cut
)
SELECT ckey, s, e,
       list_min(list_transform(duckhts_cgranges_overlaps_list(${lit(categoryIndex)}, ckey, s, e),
                               h -> h.label::INTEGER)) AS priority
FROM piece WHERE e IS NOT NULL`,
    `DELETE FROM segment WHERE priority IS NULL`,
    `SELECT duckhts_cgranges_destroy(${lit(categoryIndex)})`,
    `SELECT duckhts_cgranges_create(${lit(partitionIndex)})`,
    `SELECT bool_and(duckhts_cgranges_add(${lit(partitionIndex)}, ckey, s, e, priority)) FROM segment`,
    `SELECT duckhts_cgranges_index(${lit(partitionIndex)})`,
  ];
}

/** Counts per category for one peak file: peak centres or peak base pairs. */
export function peakCountSql({ fid, narrowPeak }, partitionIndex, settings) {
  const { mode } = settings;
  const useSummits = settings.useSummits && narrowPeak;
  const validSummit = "summit IS NOT NULL AND summit >= 0 AND summit < e - s";
  const point = useSummits ? `CASE WHEN ${validSummit} THEN s + summit ELSE s + (e - s) // 2 END` : "s + (e - s) // 2";
  const peaks = `
WITH marked AS (
  SELECT *, ckey IN (SELECT ckey FROM annotation_contig) AS matched
  FROM peak WHERE fid = ${fid} AND reason IS NULL
)`;
  const hitPriority = `coalesce(list_min(list_transform(
      duckhts_cgranges_overlaps_list(${lit(partitionIndex)}, ckey, c, c + 1), h -> h.label::INTEGER)),
      ${PRIORITY.intergenic})`;
  if (mode === "bp") {
    const genic = categoriesFor(settings).filter((c) => c !== "intergenic");
    return `${peaks}, covered AS MATERIALIZED (
  SELECT s, e, duckhts_cgranges_overlaps_list(${lit(partitionIndex)}, ckey, s, e) AS hits
  FROM marked WHERE matched
), tally AS (
  SELECT coalesce(sum(e - s), 0)::BIGINT AS total,
    ${genic.map((c) => `coalesce(sum(list_sum(list_transform(hits, h ->
      CASE WHEN h.label::INTEGER = ${PRIORITY[c]} THEN least(e, h.interval_end) - greatest(s, h.interval_start)
      ELSE 0 END))), 0)::BIGINT AS ${c}`).join(",\n    ")}
  FROM covered
)
${genic.map((c) => `SELECT ${PRIORITY[c]} AS priority, ${c} AS n FROM tally`).join("\nUNION ALL ")}
UNION ALL SELECT ${PRIORITY.intergenic}, total - (${genic.join(" + ")}) FROM tally
UNION ALL SELECT -1, count(*) FILTER (matched) FROM marked
UNION ALL SELECT -2, count(*) FILTER (NOT matched) FROM marked
UNION ALL SELECT -3, sum(e - s) FILTER (NOT matched) FROM marked`;
  }
  return `${peaks}
SELECT priority, count(*)::BIGINT AS n FROM (
  SELECT ${hitPriority} AS priority FROM (SELECT *, ${point} AS c FROM marked WHERE matched)
) GROUP BY priority
UNION ALL SELECT -1, count(*) FILTER (matched) FROM marked
UNION ALL SELECT -2, count(*) FILTER (NOT matched) FROM marked
UNION ALL SELECT -3, count(*) FILTER (NOT matched) FROM marked
${useSummits ? `UNION ALL SELECT -4, count(*) FILTER (NOT (${validSummit})) FROM marked WHERE matched` : ""}`;
}

// UCSC chrom.sizes is tab-separated. Check lengths before reducing normalized
// aliases so conflicting values cannot silently select a background denominator.
function chromSizesSql(url) {
  return `CREATE OR REPLACE TEMP TABLE chrom_length AS
WITH checked AS (
  SELECT CASE WHEN chrom IS NULL OR trim(chrom) = '' THEN error('Empty chromosome in chrom.sizes')
              ELSE duckhts_contig_key(trim(chrom)) END AS ckey,
         CASE WHEN length IS NULL OR NOT regexp_full_match(trim(length), '[0-9]+')
                   OR try_cast(length AS BIGINT) IS NULL OR try_cast(length AS BIGINT) <= 0
              THEN error('chrom.sizes length must be a positive integer')
              ELSE cast(length AS BIGINT) END AS length
  FROM read_csv(${lit(url)}, delim = '\\t', header = false, auto_detect = false,
                columns = {'chrom': 'VARCHAR', 'length': 'VARCHAR'}, comment = '#')
)
SELECT ckey, CASE WHEN min(length) <> max(length)
                 THEN error('Conflicting chromosome lengths in chrom.sizes: ' || ckey)
                 ELSE max(length) END AS length
FROM checked GROUP BY ckey;`;
}

/** Base pairs per category on annotated chromosomes with supplied lengths. */
function backgroundSql() {
  return `
WITH len AS (
  SELECT ckey, max(length) AS length FROM chrom_length
  WHERE ckey IN (SELECT ckey FROM annotation_contig) GROUP BY ckey
), covered AS (
  SELECT g.priority, sum(least(g.e, len.length) - g.s) AS n
  FROM segment g JOIN len USING (ckey) WHERE g.s < len.length GROUP BY g.priority
)
SELECT priority, n::BIGINT AS n FROM covered
UNION ALL
SELECT ${PRIORITY.intergenic}, ((SELECT sum(length) FROM len) - coalesce((SELECT sum(n) FROM covered), 0))::BIGINT
UNION ALL
SELECT -1, (SELECT sum(length) FROM len)::BIGINT`;
}

function countsFrom(rows, settings) {
  const counts = Object.fromEntries(categoriesFor(settings).map((c) => [c, 0]));
  const extra = {};
  for (const { priority, n } of rows) {
    if (priority > 0) counts[CATEGORIES[priority - 1]] += Number(n ?? 0);
    else extra[priority] = Number(n ?? 0);
  }
  return { counts, extra };
}

/**
 * Annotate peak files against one annotation.
 *
 * @param {import("@duckdb/duckdb-wasm").AsyncDuckDBConnection} conn with DuckHTS loaded
 * @param {object} request
 * @param {string} request.annotation URL of a GFF3 or GTF file, plain or gzipped
 * @param {string} [request.annotationName] Original filename, required for GTF blob URLs
 * @param {{url: string, label: string, filename?: string}[]} request.peaks BED-family URLs; filename identifies narrowPeak blob URLs
 * @param {string} [request.chromSizes] tab-separated contig/length file for annotations without sequence-region
 * @param {object} [request.settings] see DEFAULT_SETTINGS
 * @param {object} [observer] Optional phase observer for benchmarking.
 * @param {(phase: string) => void} [observer.onPhase]
 * @returns {Promise<{results: object[], background: object | null, meta: object, warnings: string[]}>}
 */
export async function annotate(conn, { annotation, annotationName = annotation, peaks, chromSizes, settings: given = {} },
  { onPhase = () => {}, cache, files } = {}) {
  const persistent = !!cache;
  cache ??= {};
  const settings = { ...DEFAULT_SETTINGS, useChromSizes: Boolean(chromSizes), ...given };
  nonNegativeInt(settings.promoterUpstream, "Promoter upstream");
  nonNegativeInt(settings.promoterDownstream, "Promoter downstream");
  nonNegativeInt(settings.downstreamWindow, "Post-TES downstream window");
  if (!["centre", "bp"].includes(settings.mode)) throw new Error(`Unknown mode: ${settings.mode}`);

  const rows = async (sql) => (await conn.query(sql)).toArray().map((r) => r.toJSON());
  const run = async (sql) => {
    for (const statement of sql.split(/;\s*\n/).map((s) => s.trim()).filter(Boolean)) {
      await conn.query(statement);
    }
  };
  const warnings = [];

  onPhase("partition");
  try {
    if (settings.useChromSizes && !chromSizes) throw new Error("Choose a chrom.sizes file or turn off its setting.");
    const sourceKey = JSON.stringify([annotation, annotationName]);
    if (cache.sourceKey !== sourceKey) {
      await clearAnnotation(conn, cache);
      // Header metadata is read once alongside the full feature scan.
      const headerLines = (
        await rows(`SELECT raw FROM read_hts_header(${lit(annotation)}, format := 'tabix', mode := 'raw') ORDER BY idx`)
      ).map((r) => r.raw);
      cache.format = annotationFormat(annotationName, headerLines);
      cache.assembly = headerLines.map((l) => ASSEMBLY.exec(l)?.[1]).find(Boolean) ?? null;
      const lengths = headerLines
        .filter((l) => l.startsWith("##sequence-region"))
        .map((l) => l.trim().split(/\s+/))
        .filter((f) => f.length >= 4 && Number.isInteger(Number(f[3])))
        .map(([, chrom, , end]) => `(duckhts_contig_key(${lit(chrom)}), ${Number(end)})`);
      await run(`CREATE OR REPLACE TEMP TABLE annotation_length (ckey VARCHAR, length BIGINT)`);
      if (lengths.length) await run(`INSERT INTO annotation_length VALUES ${lengths.join(", ")}`);
      cache.hasHeaderLengths = lengths.length > 0;
      await run(featureSql(cache.format, annotation));
      await run(`CREATE OR REPLACE TEMP TABLE annotation_contig AS SELECT DISTINCT ckey FROM feature`);
      const [{ features }] = await rows(`SELECT count(*) AS features FROM feature WHERE ckey IS NOT NULL AND s >= 0 AND e > s`);
      if (Number(features) === 0) throw new Error("No annotation features could be read. Check the annotation format and compression.");
      cache.sourceKey = sourceKey;
    }
    const lengthSource = settings.useChromSizes && !cache.hasHeaderLengths ? chromSizes : null;
    if (cache.lengthSource !== lengthSource) {
      await run(lengthSource ? chromSizesSql(lengthSource) :
        "CREATE OR REPLACE TEMP TABLE chrom_length AS SELECT * FROM annotation_length");
      cache.lengthSource = lengthSource;
      cache.background = undefined;
    }
    if (settings.useChromSizes && cache.hasHeaderLengths) {
      warnings.push("chrom.sizes was ignored because the annotation has ##sequence-region lengths.");
    }
    if (settings.proteinCodingOnly) {
      const [{ typed }] = await rows(`SELECT count(biotype) AS typed FROM tx`);
      if (Number(typed) === 0) {
        settings.proteinCodingOnly = false;
        warnings.push("The annotation has no transcript_type, gene_type or Ensembl biotype, so every transcript was kept.");
      }
    }
    const categoryKey = JSON.stringify([settings.promoterUpstream, settings.promoterDownstream, settings.proteinCodingOnly,
      settings.downstreamEnabled, settings.downstreamEnabled ? settings.downstreamWindow : 0]);
    if (cache.categoryKey !== categoryKey) {
      if (cache.partitionIndex) await conn.query(`SELECT duckhts_cgranges_destroy(${lit(cache.partitionIndex)})`);
      await run(categorySql(settings));
      const id = ++runCounter;
      cache.categoryIndex = `category_${id}`;
      cache.partitionIndex = `partition_${id}`;
      for (const statement of partitionSql(cache.categoryIndex, cache.partitionIndex)) await conn.query(statement);
      delete cache.categoryIndex;
      cache.categoryKey = categoryKey;
      cache.background = undefined;
    }
    const { partitionIndex, format, assembly } = cache;
    onPhase("count");
    files ??= await readPeaks(conn, peaks);
    const results = [];
    for (const file of files) {
      const { fid, label, error, rejected, rejectedCount } = file;
      warnings.push(...peakWarnings(file));
      const { counts, extra } = countsFrom(await rows(peakCountSql(file, partitionIndex, settings)), settings);
      const summitFallbacks = extra[-4] ?? 0;
      if (summitFallbacks > 0 && settings.mode === "centre" && settings.useSummits && file.narrowPeak && !error) {
        warnings.push(`${label}: ${summitFallbacks} peak(s) fell back to the midpoint (missing or out-of-range summit).`);
      }
      const matchedPeaks = extra[-1];
      const unmatchedPeaks = extra[-2];
      const matched = Object.values(counts).reduce((n, value) => n + value, 0);
      const unmatchedChroms = (
        await rows(`SELECT DISTINCT trim(raw_chrom) AS chrom FROM peak
          WHERE fid = ${fid} AND reason IS NULL
            AND ckey NOT IN (SELECT ckey FROM annotation_contig) ORDER BY chrom`)
      ).map((r) => r.chrom);
      const total = matchedPeaks + unmatchedPeaks;
      results.push({
        label, error, rejected, rejectedCount, summitFallbacks,
        mode: settings.mode,
        counts,
        matched,
        unmatched: extra[-3],
        peaks: { matched: matchedPeaks, unmatched: unmatchedPeaks },
        unmatchedChroms,
        drawn: total > 0 && unmatchedPeaks / total <= MAX_UNMATCHED_FRACTION,
      });
      if (unmatchedPeaks > 0) {
        warnings.push(`${label}: ${unmatchedPeaks} peak(s) on chromosomes not in the annotation (${unmatchedChroms.join(", ")}).`);
      }
    }

    let background = null;
    const [{ known }] = await rows(`SELECT count(*) AS known FROM chrom_length`);
    if (Number(known) > 0) {
      if (!cache.background) {
        const { counts, extra } = countsFrom(await rows(backgroundSql()), settings);
        cache.background = { label: "Genome", background: true, mode: "bp", counts, total: extra[-1] };
      }
      background = cache.background;
      if (lengthSource) {
        const [{ missing }] = await rows(`SELECT count(*) AS missing FROM annotation_contig
          WHERE ckey NOT IN (SELECT ckey FROM chrom_length)`);
        if (Number(missing) > 0) warnings.push(`${missing} annotation contig(s) have no length in chrom.sizes and are excluded from the Genome bar.`);
        if (background.total === 0) background = null;
      }
      for (const { fid, label } of files) {
        const [{ past }] = await rows(`SELECT count(*) AS past FROM peak b
          JOIN chrom_length l USING (ckey) WHERE fid = ${fid} AND reason IS NULL AND b.e > l.length`);
        if (Number(past) > 0) {
          warnings.push(`${label}: ${past} peak(s) extend past their chromosome's end. Is this the right genome build?`);
        }
      }
    } else {
      if (lengthSource) throw new Error("chrom.sizes contains no chromosome lengths.");
      warnings.push("No chromosome lengths, so the Genome bar is hidden. Supply chrom.sizes for annotations without ##sequence-region.");
    }

    const [{ transcripts }] = await rows(`SELECT count(*) AS transcripts FROM used_tx`);
    const meta = { annotation, format, assembly, transcripts: Number(transcripts), settings };
    return { results, background, meta, warnings };
  } catch (error) {
    await clearAnnotation(conn, cache);
    throw error;
  } finally {
    if (!persistent) await clearAnnotation(conn, cache);
    onPhase("done");
  }
}

export async function clearAnnotation(conn, cache) {
  for (const name of [cache.categoryIndex, cache.partitionIndex].filter(Boolean)) {
    await conn.query(`SELECT duckhts_cgranges_destroy(${lit(name)})`);
  }
  for (const table of ["feature", "part", "tx", "used_tx", "category_interval", "segment", "chrom_length", "annotation_length", "annotation_contig"]) {
    await conn.query(`DROP TABLE IF EXISTS ${table}`);
  }
  for (const key of Object.keys(cache)) delete cache[key];
}
