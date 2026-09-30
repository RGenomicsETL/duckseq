// One file selection and database, two SQL analyses: Where and Peek.
import * as Plot from "../vendor/plot.js";
import { openDatabase } from "./db.js";
import { localFileUrl, supportsLocalFiles } from "./duckhts-loader.js";
import { CATEGORIES, CATEGORY_LABELS, DEFAULT_SETTINGS, categoriesFor } from "./annotate.js";
import { createSession } from "./session.js";
import { createSqlConsole, mountSqlConsole } from "./sql-console.js";
import { mountExecutedSql } from "./executed-sql.js";
import { drawPeek, download } from "./peek-view.js";

/** Bundled datasets, served from this origin. */
export const DATASETS = {
  thymus: {
    name: "Mouse thymus, chr19 (GENCODE M25, ENCODE)",
    annotations: { "GENCODE vM25 basic, chr19 (GFF3)": "examples/gencode.vM25.basic.chr19.gff3.gz" },
    peaks: {
      H3K4me3: "examples/thymus_H3K4me3_ENCFF674JZY.chr19.narrowPeak.gz",
      H3K27me3: "examples/thymus_H3K27me3_ENCFF478UYW.chr19.narrowPeak.gz",
      H3K36me3: "examples/thymus_H3K36me3_ENCFF853BYO.chr19.narrowPeak.gz",
      CTCF: "examples/thymus_CTCF_ENCFF714WDP.chr19.narrowPeak.gz",
      DNase: "examples/thymus_DNase_ENCFF979ULB.chr19.narrowPeak.gz",
    },
  },
  fixture: {
    name: "Hand-built test fixture",
    annotations: {
      "fixture.gff3": "test/fixtures/fixture.gff3",
      "fixture.gtf": "test/fixtures/fixture.gtf",
    },
    peaks: {
      peaks: "test/fixtures/peaks.bed",
      "peaks-nochr": "test/fixtures/peaks-nochr.bed",
    },
  },
};
DATASETS.thymusFull = {
  name: "Mouse thymus, whole genome (Peek; ENCODE)",
  annotations: {},
  peaks: Object.fromEntries(Object.entries(DATASETS.thymus.peaks)
    .map(([label, path]) => [label, path.replace("examples/", "vendor/peek-examples/").replace(".chr19", "")])),
};

const COLORS = ["#0f766e", "#2563eb", "#7c3aed", "#d97706", "#65a30d", "#c026d3", "#9ca3af"];
const $ = (id) => document.getElementById(id);
const LOCAL_UNSUPPORTED = "This signed DuckHTS build cannot read local files (blob: URLs). Use bundled examples, or stage the pinned development build and open ?duckhts=dev. See DuckHTS #246 / PR #248.";
let localAnnotation = null;
let localPeaks = [];
let localSupported = false;
let session, db, reset = Promise.resolve();
let localSizes = null, sizesSource = null, nextSizesId = 0;
const sources = new Map();

function releaseRemovedFiles() {
  const selected = new Set([localAnnotation, ...localPeaks]);
  for (const [file, source] of sources) {
    if (!selected.has(file)) {
      source.revoke();
      sources.delete(file);
    }
  }
}

function selectSizes(file) {
  localSizes = file;
  if (sizesSource) {
    const previous = sizesSource;
    reset = reset.then(() => db.dropFile(previous));
    sizesSource = null;
  }
  if (!file) {
    $("chrom-sizes").value = "";
  }
  $("output").hidden = true;
}

function clearLocalFiles() {
  selectSizes(null);
  localAnnotation = null;
  localPeaks = [];
  releaseRemovedFiles();
  if (session) reset = reset.then(() => session.clear());
  $("local-annotation").value = "";
  $("local-peaks").value = "";
  $("annotation-name").textContent = "No annotation selected";
  $("peak-names").textContent = "No peak files selected";
  $("output").hidden = true;
}

function selectFiles(kind, files) {
  if (kind === "annotation") {
    localAnnotation = files[0] ?? null;
    $("annotation-name").textContent = localAnnotation?.name ?? "No annotation selected";
  } else {
    localPeaks = [...files];
    $("peak-names").textContent = localPeaks.map((f) => f.name).join(", ") || "No peak files selected";
  }
  releaseRemovedFiles();
  $("output").hidden = true;
}

function option(value, text) {
  const el = document.createElement("option");
  el.value = value;
  el.textContent = text;
  return el;
}

function showDataset(key) {
  $("bundled-files").hidden = key === "local";
  $("local-files").hidden = key !== "local";
  $("output").hidden = true;
  if (key === "local") return;
  clearLocalFiles();
  const dataset = DATASETS[key];
  $("annotation").replaceChildren(
    ...Object.entries(dataset.annotations).map(([name, url]) => option(url, name)),
  );
  $("peaks").replaceChildren(
    ...Object.entries(dataset.peaks).map(([label, url]) => {
      const box = document.createElement("label");
      box.className = "inline";
      box.innerHTML = `<input type="checkbox" checked> `;
      box.firstChild.value = url;
      box.firstChild.dataset.label = label;
      box.append(label);
      return box;
    }),
  );
}

function showView() {
  const isPeek = $("view").value === "peek";
  for (const id of ["where-settings", "bundled-annotation", "annotation-drop", "chrom-sizes-control", "where-results"]) $(id).hidden = isPeek;
  $("where-settings").disabled = isPeek;
  $("peek-help").hidden = !isPeek;
  $("peek-results").hidden = !isPeek;
  $("output").hidden = true;
  $("run").textContent = isPeek ? "Peek at peaks" : "Annotate peaks";
  $("dataset").querySelector('[value="thymusFull"]').disabled = !isPeek;
  if (!isPeek && $("dataset").value === "thymusFull") {
    $("dataset").value = "thymus";
    showDataset("thymus");
  }
}

function request() {
  const isLocal = $("dataset").value === "local";
  const isPeek = $("view").value === "peek";
  if (isLocal && !localSupported) throw new Error(LOCAL_UNSUPPORTED);
  if (isLocal && !isPeek && !localAnnotation) throw new Error("Choose an annotation file.");
  const url = (file) => {
    if (!sources.has(file)) sources.set(file, localFileUrl(file));
    return sources.get(file).url;
  };
  const peaks = isLocal
    ? localPeaks.map((file) => ({ url: url(file), label: file.name, filename: file.name }))
    : [...$("peaks").querySelectorAll("input:checked")].map((box) => ({
      url: new URL(box.value, location.href).href,
      label: box.dataset.label,
    }));
  if (peaks.length === 0) throw new Error("Choose at least one peak file.");
  if (isPeek) return { peaks };
  return {
    annotation: isLocal ? url(localAnnotation) : new URL($("annotation").value, location.href).href,
    annotationName: isLocal ? localAnnotation.name : $("annotation").value,
    peaks,
    settings: {
      promoterUpstream: Number($("up").value),
      promoterDownstream: Number($("down").value),
      mode: $("mode").value,
      proteinCodingOnly: $("coding").checked,
      downstreamEnabled: $("downstream-enabled").checked,
      downstreamWindow: Number($("downstream-window").value),
      useSummits: $("summits").checked,
    },
  };
}

function draw({ results, background, meta, warnings }) {
  const categories = categoriesFor(meta.settings);
  const bars = [...results.filter((r) => r.drawn), ...(background ? [background] : [])];
  const total = (r) => categories.reduce((n, c) => n + r.counts[c], 0);
  const data = bars.flatMap((r) =>
    categories.map((c) => ({ bar: r.label, category: CATEGORY_LABELS[c], share: r.counts[c] / (total(r) || 1) })),
  );
  $("chart").replaceChildren(
    Plot.plot({
      width: Math.max(480, ($("chart").clientWidth || 820) - 32),
      height: 70 + 34 * bars.length,
      marginLeft: 90,
      x: { label: "Share", percent: true, domain: [0, 100] },
      y: { label: null, domain: bars.map((r) => r.label) },
      color: { domain: categories.map((c) => CATEGORY_LABELS[c]), range: categories.map((c) => COLORS[CATEGORIES.indexOf(c)]), legend: true },
      marks: [Plot.barX(data, { x: "share", y: "bar", fill: "category", order: categories.map((c) => CATEGORY_LABELS[c]), tip: true })],
    }),
  );

  const unit = meta.settings.mode === "bp" ? "base pairs" :
    meta.settings.useSummits ? "narrowPeak summits (midpoints otherwise)" : "peak centres";
  const { promoterUpstream: up, promoterDownstream: down } = meta.settings;
  $("summary").textContent =
    `Counting ${unit}; promoter ${up} bp upstream to ${down} bp downstream of the TSS; ` +
    (meta.settings.downstreamEnabled ? `Downstream ${meta.settings.downstreamWindow} bp past TES; ` : "") +
    `priority ${categories.map((c) => CATEGORY_LABELS[c]).join(" > ")}; ` +
    `${meta.transcripts.toLocaleString()} transcripts (${meta.format.toUpperCase()}` +
    `${meta.assembly ? `, ${meta.assembly}` : ""}).`;
  const title = document.createElementNS("http://www.w3.org/2000/svg", "title");
  title.textContent = $("summary").textContent;
  $("chart").querySelector("svg").prepend(title);
  const hidden = results
    .filter((r) => !r.drawn)
    .map((r) => `${r.label}: not drawn, ${r.error ? "because the file could not be read" :
      r.peaks.matched + r.peaks.unmatched === 0 ? "because it has no accepted peaks" :
      "because more than 5% of its peaks are on chromosomes the annotation lacks"}.`);
  $("warnings").replaceChildren(
    ...[...hidden, ...warnings].map((w) => {
      const li = document.createElement("li");
      li.textContent = w;
      return li;
    }),
  );

  $("table").replaceChildren();
  const head = $("table").insertRow();
  for (const text of ["File", ...categories.map((c) => CATEGORY_LABELS[c]), "Unmatched"]) {
    const cell = document.createElement("th");
    cell.textContent = text;
    head.append(cell);
  }
  for (const r of [...results, ...(background ? [background] : [])]) {
    const row = $("table").insertRow();
    row.dataset.label = r.label;
    const name = document.createElement("th");
    name.textContent = r.label;
    row.append(name);
    for (const c of [...categories, "unmatched"]) {
      const cell = row.insertCell();
      cell.dataset.category = c;
      cell.textContent = c === "unmatched" ? (r.background ? "" : r.unmatched.toLocaleString("en")) : r.counts[c].toLocaleString("en");
    }
  }
  $("where-tsv").onclick = () => {
    const lines = [["File", ...categories.map((c) => CATEGORY_LABELS[c]), "Unmatched"],
      ...[...results, ...(background ? [background] : [])].map((r) =>
        [r.label, ...categories.map((c) => r.counts[c]), r.background ? "" : r.unmatched])];
    download("where-summary.tsv", lines.map((row) => row.map((v) => String(v).replace(/[\t\r\n]/g, " ")).join("\t")).join("\n") + "\n",
      "text/tab-separated-values");
  };
  $("where-svg").onclick = () => download("where-chart.svg",
    new XMLSerializer().serializeToString($("chart").querySelector("svg")), "image/svg+xml");
  $("output").hidden = false;
}

async function main() {
  $("downstream-enabled").checked = DEFAULT_SETTINGS.downstreamEnabled;
  $("downstream-window").value = DEFAULT_SETTINGS.downstreamWindow;
  $("summits").checked = DEFAULT_SETTINGS.useSummits;
  $("dataset").replaceChildren(...Object.entries(DATASETS).map(([key, d]) => option(key, d.name)), option("local", "Local files"));
  $("dataset").addEventListener("change", () => showDataset($("dataset").value));
  showDataset($("dataset").value);
  showView();
  $("view").addEventListener("change", showView);
  $("clear-files").addEventListener("click", clearLocalFiles);
  $("chrom-sizes").addEventListener("change", (e) => selectSizes(e.target.files[0] ?? null));
  $("clear-chrom-sizes").addEventListener("click", () => selectSizes(null));
  for (const kind of ["annotation", "peaks"]) {
    $(kind === "annotation" ? "local-annotation" : "local-peaks").addEventListener("change", (event) => selectFiles(kind, event.target.files));
    const drop = $(`${kind}-drop`);
    drop.addEventListener("dragover", (event) => event.preventDefault());
    drop.addEventListener("drop", (event) => {
      event.preventDefault();
      if (!$("files").disabled) selectFiles(kind, event.dataTransfer.files);
    });
  }

  let conn;
  try {
    const opened = await openDatabase();
    conn = opened.conn;
    db = opened.db;
    session = createSession(conn);
    localSupported = await supportsLocalFiles(conn);
    $("local-status").textContent = localSupported ? "Local files are read in this tab; nothing is uploaded." : LOCAL_UNSUPPORTED;
    $("status").textContent = `DuckDB ${opened.version} (${opened.platform}) with DuckHTS loaded.` +
      (new URLSearchParams(location.search).get("duckhts") === "dev" ? " Development build: unsigned extensions enabled." : "");
    $("run").disabled = false;
    showView();
  } catch (error) {
    $("status").textContent = `Could not start DuckDB with DuckHTS: ${error.message}`;
    $("run").textContent = "Unavailable";
    return;
  }

  const sqlConsole = mountSqlConsole($("sql-console"), createSqlConsole(session), () => {
    try { return { ...request(), live: session.context() }; }
    catch { return {}; } // A partial local selection has no file examples yet.
  }, { onBusy(busy) {
    $("run").disabled = busy;
    $("files").disabled = busy;
    $("view").disabled = busy;
    $("where-settings").disabled = busy || $("view").value === "peek";
  } });

  const showSql = Object.fromEntries(["where", "peek"].map((view) =>
    [view, mountExecutedSql($(`${view}-results`).querySelector(".executed-sql"), sqlConsole)]));

  $("form").addEventListener("submit", async (event) => {
    event.preventDefault();
    $("run").disabled = true;
    sqlConsole.setBusy(true);
    $("files").disabled = true;
    $("view").disabled = true;
    $("where-settings").disabled = true;
    $("output").hidden = true;
    delete document.body.dataset.state;
    const isPeek = $("view").value === "peek";
    $("status").textContent = isPeek ? "Checking peaks…" : "Annotating…";
    const started = performance.now();
    try {
      await reset;
      const input = request();
      if (!isPeek && localSizes) {
        if (!sizesSource) {
          const path = `chrom-sizes-${++nextSizesId}.tsv`;
          await db.registerFileBuffer(path, new Uint8Array(await localSizes.arrayBuffer()));
          sizesSource = path;
        }
        input.chromSizes = sizesSource;
      }
      const view = isPeek ? "peek" : "where";
      const result = await session.run(view, input);
      showSql[view](session.executedStatements());
      // Shown before drawing so the charts can size themselves to the results column.
      $("output").hidden = false;
      if (isPeek) drawPeek(result);
      else draw(result);
      $("status").textContent = `Done in ${((performance.now() - started) / 1000).toFixed(1)} s.`;
      document.body.dataset.state = "done";
    } catch (error) {
      $("status").textContent = error.message;
      document.body.dataset.state = "error";
    } finally {
      $("files").disabled = false;
      $("view").disabled = false;
      $("where-settings").disabled = isPeek;
      $("run").disabled = false;
      sqlConsole.setBusy(false);
      sqlConsole.refresh();
    }
  });
}

main();
