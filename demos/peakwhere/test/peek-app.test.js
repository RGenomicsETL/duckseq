import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

const expected = JSON.parse(await readFile(new URL("./fixtures/peek/expected.json", import.meta.url), "utf8"));
let session, page;
before(async () => {
  session = await openBrowser();
  page = await session.newPage("/");
  await page.waitForSelector("#run:not([disabled])");
});
after(() => session.close());
async function run(target = page) {
  await target.click("#run");
  await target.waitForSelector('body[data-state] #run:not([disabled])', { timeout: 120_000 });
  assert.equal(await target.getAttribute("body", "data-state"), "done", await target.textContent("#status"));
}
async function summary(target = page) {
  return target.$$eval("#peek-table tr[data-label]", (rows) => Object.fromEntries(rows.map((row) => [row.dataset.label,
    Object.fromEntries([...row.querySelectorAll("td")].map((cell) => [cell.dataset.metric, cell.textContent]))])));
}

test("Peek needs no annotation and renders PeakPeek's full thymus summary and both charts", async () => {
  await page.selectOption("#view", "peek");
  await page.selectOption("#dataset", "thymusFull");
  assert.equal(await page.locator("#bundled-annotation").isVisible(), false);
  assert.equal(await page.locator("#where-settings").isVisible(), false);
  await run();
  const got = await summary();
  for (const [label, oracle] of Object.entries(expected.thymus)) {
    for (const key of ["n", "min", "median", "max", "sum", "mergedBp", "chromosomes", "offMain", "duplicates"]) {
      assert.equal(Number(got[label][key].replaceAll(",", "")), oracle[key], `${label}: ${key}`);
    }
  }
  assert.equal(await page.locator("#width-chart svg[viewBox]").count(), 1);
  assert.equal(await page.locator("#chrom-chart svg[viewBox]").count(), 1);
  assert.match(await page.textContent('#peek-problems section[data-label="CTCF"]'), /1 duplicate peaks/);
  assert.match(await page.textContent("#peek-limits"), /raw-line diagnostics/);
  await page.selectOption("#width-unit", "count");
  await page.selectOption("#chrom-unit", "count");
  assert.match(await page.textContent("#width-chart"), /Peaks in bin/);
  assert.deepEqual(await summary(), got, "chart units don't change statistics");
});

test("summary TSV and SVG downloads contain actual results", async () => {
  for (const [button, name] of [["#peek-tsv", "peek-summary.tsv"], ["#width-svg", "peek-width.svg"], ["#chrom-svg", "peek-chrom.svg"]]) {
    const pending = page.waitForEvent("download");
    await page.click(button);
    const download = await pending;
    assert.equal(download.suggestedFilename(), name);
    const text = await readFile(await download.path(), "utf8");
    if (name.endsWith(".tsv")) {
      assert.match(text, /Sum of widths\tMerged bp/);
      assert.match(text, /6217728\t6003019/);
    } else {
      assert.match(text, /<svg/);
      // The export keeps the drawn size: its viewBox width equals its width attribute.
      const width = Number(/<svg[^>]* width="(\d+(?:\.\d+)?)"/.exec(text)?.[1]);
      const viewBoxWidth = Number(/<svg[^>]* viewBox="0 0 (\d+(?:\.\d+)?) /.exec(text)?.[1]);
      assert.ok(width > 0, "exported SVG has a width");
      assert.equal(viewBoxWidth, width, "viewBox width matches the drawn width");
      assert.match(text, /aria-label="(rect|bar)"/);
      assert.match(text, /CTCF/);
    }
  }
});

test("local selection is shared by Where and Peek, and annotation is optional in Peek", async () => {
  const local = await session.newPage("/?duckhts=dev");
  await local.waitForSelector("#run:not([disabled])");
  await local.evaluate(() => {
    window.urls = { created: [], revoked: [] };
    const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (b) => { const url = create(b); window.urls.created.push(url); return url; };
    URL.revokeObjectURL = (url) => { window.urls.revoked.push(url); revoke(url); };
  });
  await local.selectOption("#view", "peek");
  await local.selectOption("#dataset", "local");
  await local.setInputFiles("#local-peaks", "test/fixtures/peek/accepted.bed");
  await run(local);
  assert.equal((await summary(local))["accepted.bed"].n, "9");
  assert.equal(await local.inputValue("#local-annotation"), "");
  const urls = await local.evaluate(() => window.urls);
  assert.equal(urls.created.length, 1);
  assert.deepEqual(urls.revoked, []);
  await local.selectOption("#view", "where");
  assert.equal(await local.locator("#annotation-drop").isVisible(), true);
  assert.equal(await local.textContent("#peak-names"), "accepted.bed");
  await local.setInputFiles("#local-annotation", "test/fixtures/fixture.gff3");
  await local.setInputFiles("#local-peaks", "test/fixtures/peaks.bed");
  await run(local);
  assert.equal(await local.locator("#table tr[data-label]").count(), 2);
  await local.selectOption("#view", "peek");
  await run(local);
  assert.equal((await summary(local))["peaks.bed"].n, "17");
  assert.equal(await local.textContent("#annotation-name"), "fixture.gff3");
  const rerunUrls = await local.evaluate(() => window.urls);
  assert.equal(rerunUrls.created.length, 3, "view switch reuses the selected peak URL");
  assert.deepEqual(rerunUrls.revoked, urls.created, "replaced peaks are revoked");
  await local.click("#clear-files");
  const cleared = await local.evaluate(() => window.urls);
  assert.deepEqual(cleared.created.sort(), cleared.revoked.sort());
  await local.close();
});

test("Where keeps its chr19 dataset and analysis when leaving a Peek-only dataset", async () => {
  await page.selectOption("#view", "where");
  assert.equal(await page.inputValue("#dataset"), "thymus");
  await page.selectOption("#dataset", "fixture");
  await run();
  assert.equal(await page.locator("#where-results").isVisible(), true);
  assert.equal(await page.locator("#peek-results").isVisible(), false);
});

test("no cross-origin requests or uploads in either view", () => {
  assert.deepEqual(session.requests.filter((url) => new URL(url).origin !== session.base), []);
  assert.deepEqual(session.uploads, []);
});
