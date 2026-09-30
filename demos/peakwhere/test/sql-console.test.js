import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";
import { examples } from "../src/sql-console.js";

const expected = JSON.parse(await readFile("test/fixtures/expected.json", "utf8"));
let browser, page, api;
before(async () => {
  browser = await openBrowser();
  page = await browser.newPage("/");
  await page.waitForSelector("#run:not([disabled])");
  api = await browser.newPage("/test/harness.html");
});
after(() => browser.close());
const run = async () => {
  await page.evaluate(() => delete document.body.dataset.state);
  await page.click("#run");
  await page.waitForSelector('body[data-state="done"]');
};
const query = (sql) => api.evaluate((sql) => window.runSql(sql), sql);
const request = (name = "fixture.gff3", peak = "peaks.bed") => ({
  annotation: `${browser.base}/test/fixtures/${name}`,
  peaks: [{ url: `${browser.base}/test/fixtures/${peak}`, label: "peaks" }],
});
const analyse = (view, input) => api.evaluate(({ view, input }) => window.runSession(view, input), { view, input });
async function example(id, input) {
  const examples = await api.evaluate((input) => window.sqlExamples(input), input);
  const example = examples.find((e) => e.id === id);
  assert.ok(example, id);
  const result = await query(example.sql);
  assert.equal(result.error, null, `${id}: ${result.error}`);
  return result;
}

test("console example renders the hand-worked category counts from the live session", async () => {
  await page.selectOption("#dataset", "fixture");
  await run();
  await page.locator("#sql-console > summary").click();
  await page.selectOption("#sql-examples", "counts");
  await page.click("#sql-run");
  await page.waitForSelector("#sql-result tbody tr");
  const got = await page.$$eval("#sql-result tbody tr", (rows) => Object.fromEntries(
    rows.map((row) => [row.cells[0].textContent, Number(row.cells[1].textContent)])));
  const want = Object.fromEntries(Object.keys(got).map((c) => [c, expected.counts_centre[c]]));
  assert.deepEqual(got, want);
  assert.equal(Object.keys(got).length, 6);
  assert.equal(await page.textContent("#sql-status"), "Showing 6 of 6");
});

test("console errors stay inline; keyboard Run caps rows and renders values and headers as text", async () => {
  await page.fill("#sql-input", "SELECT * FROM table_that_does_not_exist");
  await page.press("#sql-input", "Control+Enter");
  await page.waitForFunction(() => document.querySelector("#sql-error").textContent.includes("does not exist"));
  assert.equal(await page.locator("#sql-result tbody tr").count(), 0);
  const malicious = '<img src=x onerror="window.sqlInjected=true">';
  await page.fill("#sql-input", `SELECT '${malicious}' AS "<svg onload=alert(1)>", i FROM range(1005) t(i)`);
  await page.press("#sql-input", "Meta+Enter");
  await page.waitForFunction(() => document.querySelector("#sql-status").textContent === "Showing 1000 of 1005");
  assert.equal(await page.locator("#sql-result tbody tr").count(), 1000);
  assert.equal(await page.locator("#sql-result td").first().textContent(), malicious);
  assert.equal(await page.locator("#sql-result th").first().textContent(), "<svg onload=alert(1)>");
  assert.equal(await page.locator("#sql-result img, #sql-result svg").count(), 0);
  assert.equal(await page.evaluate(() => window.sqlInjected), undefined);
  assert.equal(await page.textContent("#sql-error"), "");
});

test("API reports errors and totals, preserves duplicate columns and exact integers", async () => {
  const got = await query("SELECT 9223372036854775807::BIGINT AS x, NULL AS x, i FROM range(1005) t(i)");
  assert.deepEqual(got.columns, ["x", "x", "i"]);
  assert.deepEqual(got.rows[0], [9223372036854775807n, null, 0n]);
  assert.equal(got.rows.length, 1000);
  assert.equal(got.total, 1005);
  assert.equal(got.error, null);
  const error = await query("not sql");
  assert.match(error.error, /Parser Error/);
  assert.deepEqual(error.rows, []);
});

test("page Run recovers after console drops and replaces cached tables, including a partial failing script", async () => {
  await page.fill("#sql-input", "DROP TABLE feature; CREATE OR REPLACE TEMP TABLE peak AS SELECT 1 AS wrong; SELECT * FROM missing_table");
  await page.click("#sql-run");
  await page.waitForFunction(() => document.querySelector("#sql-error").textContent.includes("missing_table"));
  await run();
  const counts = await page.$$eval('#table tr[data-label="peaks"] td[data-category]', (cells) =>
    Object.fromEntries(cells.map((c) => [c.dataset.category, Number(c.textContent)])));
  for (const category of ["promoter", "utr5", "utr3", "exon", "intron", "intergenic"]) {
    assert.equal(counts[category], expected.counts_centre[category]);
  }
});

test("examples use the current selected URLs and quote them as SQL literals", () => {
  const selected = { annotation: "blob:annotation", annotationName: "example.gtf.gz",
    peaks: [{ url: "blob:peak'quoted", filename: "selected.narrowPeak.gz" }] };
  const queries = examples(selected);
  assert.match(queries.find((e) => e.id === "read-bed").sql, /read_bed\('blob:peak''quoted'/);
  assert.match(queries.find((e) => e.id === "read-annotation").sql, /read_gtf\('blob:annotation'/);
  assert.match(queries.find((e) => e.id === "narrowpeak").sql, /'signal_value', 'p_value', 'q_value', 'peak'/);
  assert.match(queries.find((e) => e.id === "gzip").sql, /blob:peak''quoted/);
  assert.doesNotMatch(queries.map((q) => q.sql).join("\n"), /examples\/|test\/fixtures/);
});

test("examples expose resolved Ensembl and gene-line coding types, GTF 2.2 UTRs and scoped reused IDs", async () => {
  // Coding transcripts by hand: tA, tB, tC in the Ensembl fixtures (tD is lncRNA);
  // t1 on chrF and t3 in gene-types and gencode (t2 and chrG's t1 are lncRNA).
  const coding = { "ensembl.gtf": 3, "ensembl.gff3": 3, "gene-types.gtf": 2, "gencode.gtf": 2 };
  for (const [name, n] of Object.entries(coding)) {
    const input = request(name);
    await analyse("where", input);
    const coding = await example("coding", input);
    assert.equal(coding.rows.length, n, name);
    assert.ok(coding.rows.every((r) => r[3] === "protein_coding"));
  }
  const ucsc = request("ucsc.gtf");
  await analyse("where", ucsc);
  assert.deepEqual((await example("utr", ucsc)).rows, [["3utr", "utr3", 3n], ["5utr", "utr5", 3n]]);
  const reused = request("reused-id.gtf");
  await analyse("where", reused);
  assert.deepEqual((await example("reused-id", reused)).rows.map((r) => r.slice(0, 3)),
    [["tC", "F", "+"], ["tC", "G", "+"]]);
});

test("all available fixture examples execute; retained Peek tables and analysis serialization work", async () => {
  const input = request();
  await analyse("where", input);
  const queries = await api.evaluate((input) => window.sqlExamples(input), input);
  for (const { id, sql } of queries) assert.equal((await query(sql)).error, null, id);
  const peek = await analyse("peek", input);
  const widths = await example("peek", input);
  assert.equal(Number(widths.rows[0][1]), peek.results[0].n);
  const concurrent = await api.evaluate(async (input) => {
    const change = window.runSql("DROP TABLE peak");
    const run = window.runSession("where", input);
    return { change: await change, result: await run };
  }, input);
  assert.equal(concurrent.change.error, null);
  assert.equal(concurrent.result.results[0].counts.promoter, expected.counts_centre.promoter);
});

test("summit, downstream, chrom.sizes and compressed examples query selected inputs", async () => {
  const input = { ...request("gene-types.gtf", "summits.narrowPeak.bgz"),
    chromSizes: `${browser.base}/test/fixtures/gene-types.chrom.sizes`,
    settings: { useSummits: true, useChromSizes: true, downstreamEnabled: true } };
  await analyse("where", input);
  assert.equal((await example("gzip", input)).rows[0][0], 10n);
  assert.equal((await example("narrowpeak", input)).rows.length, 10);
  const summit = await example("summits", input);
  assert.equal(summit.rows.filter((r) => r[5]).length, 5);
  assert.ok((await example("downstream", input)).rows.length > 0);
  assert.ok((await example("chrom-sizes", input)).rows.length > 0);
});

test("SQL console makes no off-origin requests", () => {
  assert.deepEqual(browser.requests.filter((url) => !url.startsWith(browser.base)), []);
});
