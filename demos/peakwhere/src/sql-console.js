import { CATEGORIES, categoriesFor, peakCountSql } from "./annotate.js";
import { narrowPeakReader } from "./peaks.js";

const lit = (value) => `'${String(value).replaceAll("'", "''")}'`;

/** Same session as the analysis. The cap limits returned/displayed rows, not SQL work. */
export function createSqlConsole(session, { maxRows = 1000 } = {}) {
  return {
    async runQuery(sql) {
      try {
        const table = await session.query(sql);
        const columns = table.schema.fields.map((f) => f.name);
        const rows = Array.from({ length: Math.min(maxRows, table.numRows) }, (_, i) =>
          columns.map((_, j) => table.getChildAt(j).get(i)));
        return { columns, rows, total: table.numRows, error: null };
      } catch (error) {
        return { columns: [], rows: [], total: 0, error: error.message };
      }
    },
    examples,
  };
}

/** URLs are supplied at insertion time; live tables describe the last analysis. */
export function examples({ annotation, annotationName = annotation, peaks = [], live = {} } = {}) {
  const queries = [];
  const add = (id, label, sql) => queries.push({ id, label, sql });
  const selected = peaks[0];
  const file = live.files?.find((f) => f.url === selected?.url && f.label === selected?.label);
  if (live.view === "where" && annotation === live.annotation) {
    if (file) {
      const counts = peakCountSql(file, live.partitionIndex, live.settings);
      const categories = categoriesFor(live.settings).map((c) => `(${CATEGORIES.indexOf(c) + 1}, ${lit(c)})`).join(", ");
      add("counts", "Category counts", `WITH counts AS (${counts})
SELECT category, coalesce(n, 0) AS n
FROM (VALUES ${categories}) categories(priority, category)
LEFT JOIN counts USING (priority)
ORDER BY priority;`);
    }
    add("coding", "Protein-coding types", `-- biotype resolves transcript_type/transcript_biotype, gene_type/gene_biotype and gene-line types.
SELECT tx, ckey, strand, biotype
FROM tx
WHERE biotype = 'protein_coding'
ORDER BY ckey, strand, tx;`);
    if (live.format === "gtf") add("reused-id", "Transcript IDs per chromosome and strand", `SELECT transcript_id, ckey, strand, min(s) AS s, max(e) AS e
FROM feature
WHERE kind = 'exon' AND transcript_id IN (
  SELECT transcript_id FROM feature WHERE kind = 'exon'
  GROUP BY transcript_id HAVING count(DISTINCT (ckey, strand)) > 1)
GROUP BY transcript_id, ckey, strand
ORDER BY transcript_id, ckey, strand;`);
    add("utr", "UTR feature names", `SELECT type, kind, count(*) AS n
FROM feature
WHERE kind IN ('utr5', 'utr3')
GROUP BY type, kind
ORDER BY type;`);
    add("downstream", "Downstream intervals", `SELECT ckey, s, e
FROM category_interval
WHERE priority = 6
ORDER BY ckey, s, e;`);
    add("chrom-sizes", "Chromosome lengths", `SELECT ckey, length, sum(length) OVER () AS genome_bp
FROM chrom_length
WHERE ckey IN (SELECT ckey FROM annotation_contig)
ORDER BY ckey;`);
  }
  if (file?.narrowPeak) {
    add("summits", "Summit positions and midpoint fallbacks", `SELECT raw_chrom, s, e, summit,
  CASE WHEN summit IS NOT NULL AND summit >= 0 AND summit < e - s
    THEN s + summit ELSE s + (e - s) // 2 END AS position,
  NOT (summit IS NOT NULL AND summit >= 0 AND summit < e - s) AS midpoint_fallback
FROM peak
WHERE fid = ${file.fid} AND reason IS NULL;`);
  }
  if (selected) {
    add("read-bed", "Read selected peaks", `SELECT *
FROM read_bed(${lit(selected.url)}, scan_mode := 'sequential')
LIMIT 20;`);
    if (/\.narrowPeak(?:\.(?:gz|bgz))?$/i.test(selected.filename ?? selected.url)) {
      add("narrowpeak", "Declared narrowPeak columns", `SELECT *
FROM ${narrowPeakReader(selected.url)}
LIMIT 20;`);
    }
  }
  const annotationReader = /\.gtf(?:\.(?:gz|bgz))?$/i.test(annotationName) ? "read_gtf" : "read_gff";
  if (annotation) add("read-annotation", "Read selected annotation", `SELECT feature, count(*) AS n
FROM ${annotationReader}(${lit(annotation)}, scan_mode := 'sequential')
GROUP BY feature
ORDER BY n DESC, feature;`);
  const compressedPeak = peaks.find((p) => /\.(gz|bgz)$/i.test(p.filename ?? p.url));
  const compressedAnnotation = /\.(gz|bgz)$/i.test(annotationName ?? "");
  if (compressedPeak || compressedAnnotation) {
    add("gzip", "Count compressed rows with htslib", `SELECT count(*) AS n
FROM ${compressedPeak ? "read_bed" : annotationReader}(${lit(compressedPeak?.url ?? annotation)}, scan_mode := 'sequential');`);
  }
  if (live.view === "peek") add("peek", "Peak widths by file", `SELECT fid, count(*) AS n, min(w) AS min_width, median(w) AS median_width,
  max(w) AS max_width, sum(w) AS total_bp
FROM peek_valid
GROUP BY fid
ORDER BY fid;`);
  add("tables", "Session tables", "SHOW TABLES;");
  return queries;
}

const display = (value) => value == null ? "NULL" : typeof value === "object"
  ? JSON.stringify(value, (_, v) => typeof v === "bigint" ? String(v) : v) : String(value);

/** Markup is replaceable; the API above has no DOM dependency. */
export function mountSqlConsole(root, api, selection, { onBusy = () => {} } = {}) {
  const find = (id) => root.querySelector(`#${id}`);
  const input = find("sql-input"), run = find("sql-run"), select = find("sql-examples");
  let busy = false;
  const load = (sql) => {
    root.open = true;
    input.value = sql;
    input.focus();
    input.setSelectionRange(0, 0);
    input.scrollTop = 0;
  };
  function refresh() {
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = "Pick one…";
    select.replaceChildren(placeholder, ...api.examples(selection()).map(({ id, label }) => {
      const option = document.createElement("option");
      option.value = id;
      option.textContent = label;
      return option;
    }));
  }
  function setBusy(value) {
    busy = value;
    run.disabled = value;
    select.disabled = value;
  }
  async function execute() {
    if (busy) return;
    setBusy(true);
    onBusy(true);
    find("sql-error").textContent = "";
    find("sql-status").textContent = "Running";
    const { columns, rows, total, error } = await api.runQuery(input.value);
    const table = find("sql-result");
    table.replaceChildren();
    if (columns.length) {
      const header = table.createTHead().insertRow();
      for (const name of columns) {
        const cell = document.createElement("th");
        cell.scope = "col";
        cell.textContent = name;
        header.append(cell);
      }
      const body = table.createTBody();
      for (const values of rows) {
        const row = body.insertRow();
        for (const value of values) {
          const cell = row.insertCell();
          cell.textContent = display(value);
          if (value == null) cell.className = "null";
          else if (typeof value === "number" || typeof value === "bigint") cell.className = "num";
        }
      }
    }
    // Numeric columns align right, header included.
    rows[0]?.forEach((value, j) => {
      if (typeof value === "number" || typeof value === "bigint") table.tHead.rows[0].cells[j].className = "num";
    });
    find("sql-error").textContent = error ?? "";
    find("sql-status").textContent = error ? "" : `Showing ${rows.length} of ${total}`;
    setBusy(false);
    onBusy(false);
  }
  select.addEventListener("change", () => {
    const example = api.examples(selection()).find((e) => e.id === select.value);
    if (example) load(example.sql);
  });
  root.addEventListener("toggle", () => { if (root.open) refresh(); });
  run.addEventListener("click", execute);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      void execute();
    }
  });
  refresh();
  return { load, refresh, setBusy };
}
