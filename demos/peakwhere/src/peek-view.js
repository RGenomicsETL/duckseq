// Display and downloads only. All file statistics and bins come from peek.js SQL.
import * as Plot from "../vendor/plot.js";
const $ = (id) => document.getElementById(id);
const COLUMNS = [
  ["label", "File"], ["n", "Valid peaks"], ["min", "Min bp"], ["median", "Median bp"],
  ["mean", "Mean bp"], ["max", "Max bp"], ["sum", "Sum of widths"], ["mergedBp", "Merged bp"],
  ["chromosomes", "Chromosomes"], ["offMain", "Off main"], ["duplicates", "Duplicates"],
  ["overlapping", "Overlapping"], ["over100kb", ">100 kb"], ["rejectedCount", "Excluded rows"],
  ["chromStyle", "Chromosome style"], ["error", "Read error"],
];
const COLORS = ["#0f766e", "#2563eb", "#c026d3", "#d97706", "#65a30d", "#dc2626"];
const fmt = (value) => typeof value === "number" ? value.toLocaleString("en", { maximumFractionDigits: 2 }) : value ?? "—";

function element(tag, text) {
  const node = document.createElement(tag);
  node.textContent = text;
  return node;
}
function table(target, columns, rows) {
  target.replaceChildren();
  const head = target.insertRow();
  for (const [, label] of columns) head.append(element("th", label));
  for (const row of rows) {
    const tr = target.insertRow();
    if (row.label != null) tr.dataset.label = row.label;
    for (const [key] of columns) {
      const cell = tr.insertCell();
      cell.dataset.metric = key;
      cell.textContent = row.error && !["label", "error"].includes(key) ? "—" : fmt(row[key]);
    }
  }
}
export function download(name, data, type) {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
function charts({ results, aligned }) {
  const files = results.filter((r) => r.n > 0);
  const byId = new Map(results.map((r, i) => [r.fid, { ...r, title: `${i + 1}. ${r.label}` }]));
  const label = (fid) => byId.get(fid).title;
  const domain = files.map((r) => label(r.fid));
  const color = { domain, range: COLORS, legend: true };
  const percentWidth = $("width-unit").value === "fraction";
  const widths = files.flatMap((r) => r.histogram.map((bin) => ({
    ...bin, file: label(r.fid), value: percentWidth ? bin.n / r.n * 100 : bin.n,
  })));
  $("width-chart").replaceChildren(...(files.length ? [Plot.plot({
    width: Math.max(480, $("output").clientWidth || 820), height: 300, marginLeft: 60,
    x: { type: "log", label: "Peak width (bp)", domain: [widths[0].from, widths.at(-1).to] },
    y: { label: percentWidth ? "Peaks in bin (%)" : "Peaks in bin", grid: true }, color,
    marks: [Plot.rectY(widths, { x1: "from", x2: "to", y1: 0, y2: "value", fill: "file", fillOpacity: 0.25,
      stroke: "file", tip: true, title: (d) => `${d.file}: ${d.n} peaks; ${fmt(d.from)}–${fmt(d.to)} bp` })],
  })] : [element("p", "No valid peaks to plot.")]));
  const percentChrom = $("chrom-unit").value === "fraction";
  const chroms = [...new Set(aligned.map((r) => r.chrom))];
  const counts = aligned.map((r) => ({ ...r, file: label(r.fid), value: percentChrom ? r.n / byId.get(r.fid).n * 100 : r.n }));
  $("chrom-chart").replaceChildren(...(files.length ? [Plot.plot({
    width: Math.max(480, $("output").clientWidth || 820), height: Math.max(200, 90 * files.length),
    marginLeft: 60, marginRight: 110,
    x: { label: "Chromosome (aligned names)", domain: chroms },
    y: { label: percentChrom ? "Peaks (%)" : "Peaks", grid: true, ticks: 2 },
    fy: { domain, label: null }, color,
    marks: [Plot.barY(counts, { x: "chrom", y: "value", fy: "file", fill: "file", tip: true,
      title: (d) => `${d.file}: ${d.chrom}, ${d.n} peaks` })],
  })] : [element("p", "No valid peaks to plot.")]));
  for (const id of ["width", "chrom"]) {
    $(`${id}-svg`).disabled = !files.length;
    $(`${id}-svg`).onclick = () => {
      const svg = $(`${id}-chart`).querySelector("svg[viewBox]").cloneNode(true);
      // Plot's HTML legend is outside the SVG; include a visible key in the export.
      const width = Number(svg.getAttribute("width"));
      const height = Number(svg.getAttribute("height"));
      svg.setAttribute("height", height + 24 * files.length);
      svg.setAttribute("viewBox", `0 0 ${width} ${height + 24 * files.length}`);
      files.forEach((r, i) => {
        const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
        text.setAttribute("x", "70"); text.setAttribute("y", String(height + 18 + i * 24));
        text.setAttribute("fill", COLORS[i % COLORS.length]);
        text.setAttribute("text-anchor", "start");
        text.textContent = label(r.fid);
        svg.append(text);
      });
      download(`peek-${id}.svg`, new XMLSerializer().serializeToString(svg), "image/svg+xml");
    };
  }
}

export function drawPeek(report) {
  table($("peek-table"), COLUMNS, report.results);
  $("peek-problems").replaceChildren();
  for (const r of report.results) {
    const section = document.createElement("section");
    section.dataset.label = r.label;
    section.append(element("h3", r.label));
    const problems = [];
    if (r.error) problems.push(`Could not read this file; no statistics are reported: ${r.error}`);
    for (const rejection of r.rejected) problems.push(`${fmt(rejection.n)} returned rows excluded: ${rejection.reason}.`);
    if (r.duplicates) problems.push(`${fmt(r.duplicates)} duplicate peaks (same chromosome/start/end): counted, not dropped.`);
    if (r.overlapping) problems.push(`${fmt(r.overlapping)} peaks overlap another; sum of widths ${fmt(r.sum)} bp, merged ${fmt(r.mergedBp)} bp.`);
    if (r.chromStyle === "mixed") problems.push(`Mixed chromosome names: ${fmt(r.withChr)} peaks with chr, ${fmt(r.n - r.withChr)} without.`);
    if (r.offMain) problems.push(`${fmt(r.offMain)} peaks off the main chromosomes (numbered, X, Y, M/MT), plotted as other.`);
    if (r.over100kb) problems.push(`${fmt(r.over100kb)} peaks wider than 100 kb.`);
    if (r.n + r.rejectedCount > 1000000) problems.push("More than 1,000,000 returned rows; large files may be slow. All rows are included.");
    if (!r.n && !r.error) problems.push("No valid peaks.");
    const list = document.createElement("ul");
    list.append(...problems.map((p) => element("li", p)));
    section.append(problems.length ? list : element("p", "No interval problems in the rows DuckHTS returned. Raw-line diagnostics are unavailable."));
    if (r.n) {
      const details = element("details", "");
      details.append(element("summary", "Five smallest and largest peaks (0-based half-open)"));
      const extremes = document.createElement("table");
      table(extremes, [["kind", "Group"], ["chrom", "Chromosome"], ["s", "Start"], ["e", "End"], ["w", "Width"], ["name", "Name"]], r.extremes);
      const scroll = element("div", ""); scroll.className = "scroll"; scroll.append(extremes);
      details.append(scroll); section.append(details);
    }
    $("peek-problems").append(section);
  }
  charts(report);
  $("width-unit").onchange = $("chrom-unit").onchange = () => charts(report);
  $("peek-tsv").onclick = () => {
    // Keep filenames from becoming spreadsheet formulas or extra rows/columns.
    const cell = (value) => {
      const text = String(value ?? "").replaceAll(/[\t\r\n]/g, " ");
      return /^[=+@-]/.test(text) ? `'${text}` : text;
    };
    const lines = [COLUMNS.map(([, label]) => label).join("\t"), ...report.results.map((r) =>
      COLUMNS.map(([key]) => cell(r.error && !["label", "error"].includes(key) ? null : r[key])).join("\t"))];
    download("peek-summary.tsv", lines.join("\n") + "\n", "text/tab-separated-values");
  };
}
