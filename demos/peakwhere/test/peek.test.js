import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

const expected = JSON.parse(await readFile(new URL("./fixtures/peek/expected.json", import.meta.url), "utf8"));
const { W2 } = JSON.parse(await readFile(new URL("../bench/manifest.json", import.meta.url), "utf8"));
let session, signed, dev;
before(async () => {
  session = await openBrowser();
  signed = await session.newPage("/test/harness.html");
  dev = await session.newPage("/test/harness.html?duckhts=dev");
});
after(() => session.close());

async function textPeaks(texts) {
  return dev.evaluate(async (texts) => {
    const { localFileUrl } = await import("/src/duckhts-loader.js");
    const sources = texts.map((text) => localFileUrl(new Blob([text])));
    try {
      return await window.runPeek({ peaks: sources.map(({ url }, i) => ({ url, label: `file${i}` })) });
    } finally { sources.forEach((s) => s.revoke()); }
  }, texts);
}
function compare(result, oracle) {
  for (const [key, value] of Object.entries(oracle)) {
    if (key === "perChrom") assert.deepEqual(result.perChrom.map(({ chrom, n }) => ({ chrom, n })), value);
    else if (key === "histogramCounts") assert.deepEqual(result.histogram.map((b) => b.n), value);
    else if (key === "meanRounded") {
      assert.equal(Math.round(result.mean), value);
      assert.equal(result.mean, oracle.sum / oracle.n);
    } else assert.equal(result[key], value, key);
  }
}

for (const build of ["signed", "dev"]) {
  test(`${build} Peek: PeakPeek's hand-worked fixture statistics`, async () => {
    const page = build === "signed" ? signed : dev;
    const { results } = await page.evaluate(() => window.runPeek({
      peaks: [{ label: "fixture", url: `${location.origin}/test/fixtures/peek/accepted.bed` }],
    }));
    compare(results[0], expected.fixture);
    assert.equal(results[0].histogram.length, 30);
    assert.equal(results[0].histogram.reduce((n, b) => n + b.n, 0), 9);
    assert.equal(results[0].histogram[0].from, 1);
    assert.equal(results[0].histogram.at(-1).to, 1000);
    assert.equal(results[0].histogram.at(-1).n, 1);
  });
  test(`${build} Peek: all five full thymus files match PeakPeek SPEC §2`, async () => {
    const page = build === "signed" ? signed : dev;
    const peaks = W2.filter((f) => f.path.endsWith(".narrowPeak.gz")).map((f) => {
      const name = f.path.split("/").at(-1);
      return { label: name.split("_")[1], url: `${session.base}/vendor/peek-examples/${name}` };
    });
    const { results } = await page.evaluate((peaks) => window.runPeek({ peaks }), peaks);
    for (const r of results) {
      assert.equal(r.error, null);
      assert.deepEqual(r.rejected, []);
      compare(r, expected.thymus[r.label]);
      assert.equal(r.histogram.reduce((n, b) => n + b.n, 0), r.n);
      assert.deepEqual(r.histogram.map(({ from, to }) => [from, to]), results[0].histogram.map(({ from, to }) => [from, to]));
    }
  });
}

test("touching is merged, not overlapping; nests overlap; duplicate coordinates ignore names", async () => {
  const { results } = await textPeaks([
    "chr1\t0\t10\ta\nchr1\t10\t20\tb\n",
    "chr1\t0\t100\nchr1\t10\t20\nchr1\t12\t15\nchr1\t30\t31\n",
    "chr1\t0\t10\ta\nchr1\t0\t10\tb\nchr1\t0\t11\tc\n",
  ]);
  compare(results[0], { n: 2, min: 10, median: 10, mean: 10, max: 10, sum: 20, mergedBp: 20, overlapping: 0, duplicates: 0 });
  compare(results[1], { n: 4, min: 1, median: 6.5, mean: 28.5, max: 100, sum: 114, mergedBp: 100, overlapping: 4, duplicates: 0 });
  compare(results[2], { n: 3, sum: 31, mergedBp: 11, overlapping: 3, duplicates: 1 });
});

test("problem counts, strict >100kb, raw-name statistics and aligned chromosome chart", async () => {
  const { results: [r], aligned } = await textPeaks([
    "chr1\t0\t0\nchr1\t10\t9\nchr1\t-1\t3\nchr1\tabc\t3\n" +
    "chr1\t0\t100000\nchr1\t0\t100001\n1\t0\t100000\nchrUn_2\t0\t2\nchrUn_10\t0\t3\nchr2\t0\t10\n",
  ]);
  compare(r, { n: 6, chromosomes: 5, offMain: 2, withChr: 5, over100kb: 1, duplicates: 0,
    overlapping: 2, sum: 300016, mergedBp: 200016, chromStyle: "mixed" });
  assert.deepEqual(r.rejected.map(({ reason, n }) => [reason, n]), [
    ["end before start", 1], ["negative coordinate", 1], ["non-integer or missing coordinate", 1], ["zero width", 1],
  ]);
  assert.deepEqual(r.perChrom.map(({ chrom, n }) => [chrom, n]), [["1", 1], ["chr1", 2], ["chr2", 1], ["other", 2]]);
  assert.deepEqual(aligned.map(({ chrom, n }) => [chrom, n]), [["1", 3], ["2", 1], ["other", 2]]);
});

test("empty files and equal widths have defined summaries and bins; reruns release relations", async () => {
  const { results: [empty] } = await textPeaks([""]);
  compare(empty, { n: 0, min: null, median: null, mean: null, max: null, sum: 0, mergedBp: 0, duplicates: 0 });
  assert.deepEqual(empty.histogram, []);
  const { results: [same, blank] } = await textPeaks(["chr1\t0\t5\nchr2\t0\t5\nchr3\t0\t5\n", ""]);
  assert.deepEqual(blank.histogram.map((b) => b.n), Array(30).fill(0));
  assert.equal(same.histogram[0].from, 5);
  assert.equal(same.histogram[0].n, 3);
  assert.equal(same.histogram.at(-1).to, 6);
  assert.deepEqual(await dev.evaluate(() => window.query("SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'peek_%'")), []);
});

// Reader limits, not approximations to PeakPeek's parser. Browser-reader work is tracked
// at https://github.com/RGenomicsETL/duckhts/issues/250; these semantic gaps need upstream APIs.
test("DuckHTS reader limits: scientific notation is NULL; decimal narrowPeak fields are unavailable", async () => {
  const rows = await dev.evaluate(async () => {
    const { localFileUrl } = await import("/src/duckhts-loader.js");
    const source = localFileUrl(new Blob(["chr1\t1e+03\t1100\tk\t1\t.\t4.76064\t12.91286\t10.60798\t110\n"]));
    try { return await window.query(`SELECT start, thick_start, thick_end FROM read_bed('${source.url}', scan_mode := 'sequential')`); }
    finally { source.revoke(); }
  });
  assert.deepEqual(rows, [{ start: null, thick_start: null, thick_end: null }]);
});

test("DuckHTS short-row limit aborts that file, not its valid neighbour", async () => {
  const { results } = await signed.evaluate(() => window.runPeek({ peaks: [
    { label: "original", url: `${location.origin}/test/fixtures/peek/original.bed` },
    { label: "accepted", url: `${location.origin}/test/fixtures/peek/accepted.bed` },
  ] }));
  assert.match(results[0].error, /column|field/i);
  assert.equal(results[0].n, 0);
  compare(results[1], expected.fixture);
});

test("cgranges int32 limit is reported, not silently truncated", async () => {
  const { results: [r] } = await textPeaks(["chr1\t0\t2147483648\n"]);
  assert.deepEqual(r.rejected.map(({ reason, n }) => [reason, n]), [["coordinate exceeds the cgranges 32-bit range", 1]]);
  await assert.rejects(dev.evaluate(async () => {
    await window.query("SELECT duckhts_cgranges_create('range_limit')");
    try { await window.query("SELECT duckhts_cgranges_add('range_limit', 'chr1', 0, 2147483648)"); }
    finally { await window.query("SELECT duckhts_cgranges_destroy('range_limit')"); }
  }), /int32 range/);
});

test("Peek sends neither outside-origin requests nor uploads", () => {
  assert.deepEqual(session.requests.filter((url) => new URL(url).origin !== session.base), []);
  assert.deepEqual(session.uploads, []);
});
