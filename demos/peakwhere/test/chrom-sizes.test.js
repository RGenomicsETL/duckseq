import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

let env, page;
before(async () => {
  env = await openBrowser();
  page = await env.newPage("/test/harness.html");
});
after(() => env.close());
const background = (promoter, exon, intergenic) => ({ promoter, utr5: 0, utr3: 0, exon, intron: 0, intergenic });
const expected = JSON.parse(await readFile("test/fixtures/expected.json", "utf8"));

test("optional chrom.sizes supplies GTF background and invalidates only length-dependent state", async () => {
  const runs = await page.evaluate(async () => {
    await window.clearSession();
    const base = `${location.origin}/test/fixtures/`;
    const request = { annotation: `${base}gene-types.gtf`,
      peaks: [{ url: `${base}gene-types.bed`, label: "genes" }],
      chromSizes: `${base}gene-types.chrom.sizes`, settings: { promoterUpstream: 0, promoterDownstream: 0, useChromSizes: false } };
    const off = await window.runSession("where", request);
    window.takeQueries();
    delete request.settings.useChromSizes;
    const on = await window.runSession("where", request);
    const again = await window.runSession("where", request);
    request.chromSizes = `${base}gene-types-larger.chrom.sizes`;
    const larger = await window.runSession("where", request);
    request.chromSizes = `${base}gene-types-clipped.chrom.sizes`;
    const clipped = await window.runSession("where", request);
    delete request.chromSizes;
    const disabled = await window.runSession("where", request);
    return { off, on, again, larger, clipped, disabled, sql: window.takeQueries().join("\n") };
  });
  assert.equal(runs.off.background, null);
  assert.deepEqual(runs.on.background?.counts, background(4, 396, 1100));
  assert.deepEqual(runs.again.background, runs.on.background);
  assert.deepEqual(runs.larger.background.counts, background(4, 396, 1400));
  assert.deepEqual(runs.clipped.background.counts, background(1, 49, 200));
  assert.match(runs.clipped.warnings.join("\n"), /4 peak\(s\) extend/);
  assert.equal(runs.disabled.background, null);
  for (const run of [runs.on, runs.again, runs.larger, runs.clipped, runs.disabled]) {
    assert.deepEqual(run.results[0].counts, { promoter: 0, utr5: 0, utr3: 0, exon: 4, intron: 0, intergenic: 0 });
  }
  assert.equal((runs.sql.match(/read_csv\(/g) ?? []).length, 3);
  assert.doesNotMatch(runs.sql, /read_bed|read_gtf|read_hts_header|CREATE OR REPLACE TEMP TABLE category_interval/);
});

test("sequence-region lengths take precedence over a supplied chrom.sizes file", async () => {
  const got = await page.evaluate(async () => {
    await window.clearSession();
    window.takeQueries();
    const base = `${location.origin}/test/fixtures/`;
    const result = await window.runSession("where", { annotation: `${base}fixture.gff3`,
      peaks: [{ url: `${base}peaks.bed`, label: "peaks" }],
      chromSizes: `${base}conflicting.chrom.sizes`, settings: { useChromSizes: true } });
    return { result, sql: window.takeQueries().join("\n") };
  });
  for (const [key, value] of Object.entries(got.result.background.counts)) assert.equal(value, expected.genomeBackground_bp[key]);
  assert.doesNotMatch(got.sql, /read_csv/);
  assert.match(got.result.warnings.join("\n"), /chrom.sizes.*ignored.*sequence-region/);
});

test("invalid chrom.sizes lengths fail explicitly and leave the session reusable", async () => {
  for (const [file, message] of [["conflicting", /Conflicting chromosome lengths/], ["fractional", /positive integer/]]) {
    await assert.rejects(page.evaluate(async (file) => {
      const base = `${location.origin}/test/fixtures/`;
      return window.runSession("where", { annotation: `${base}gene-types.gtf`,
        peaks: [{ url: `${base}gene-types.bed`, label: "genes" }],
        chromSizes: `${base}${file}.chrom.sizes`, settings: { useChromSizes: true } });
    }, file), message);
  }
  const recovered = await page.evaluate(() => {
    const base = `${location.origin}/test/fixtures/`;
    return window.runSession("where", { annotation: `${base}gene-types.gtf`,
      peaks: [{ url: `${base}gene-types.bed`, label: "genes" }],
      chromSizes: `${base}gene-types.chrom.sizes`,
      settings: { useChromSizes: true, promoterUpstream: 0, promoterDownstream: 0 } });
  });
  assert.deepEqual(recovered.background.counts, background(4, 396, 1100));
  await page.evaluate(() => window.clearSession());
  assert.deepEqual(await page.evaluate(() => window.query("SELECT table_name FROM duckdb_tables() WHERE temporary")), []);
});

test("selecting and clearing chrom.sizes controls the GTF Genome bar", async () => {
  const app = await env.newPage("/");
  await app.waitForFunction(() => !document.querySelector("#run").disabled);
  await app.selectOption("#dataset", "fixture");
  await app.selectOption("#annotation", "test/fixtures/fixture.gtf");
  // fixture.gtf has the same chrF features as fixture.gff3; F=30000 reproduces
  // the hand-worked genomeBackground_bp arithmetic in expected.json.
  assert.equal(await app.locator("#files #chrom-sizes").count(), 1);
  assert.equal(await app.locator("#use-chrom-sizes").count(), 0);
  for (const enabled of [true, false, true]) {
    if (enabled) await app.setInputFiles("#chrom-sizes", { name: "fixture.chrom.sizes", mimeType: "text/plain", buffer: Buffer.from("F\t30000\n") });
    else await app.click("#clear-chrom-sizes");
    await app.click("#run");
    await app.waitForSelector('body[data-state="done"] #run:not([disabled])');
    assert.equal(await app.locator('#table [data-label="Genome"]').count(), enabled ? 1 : 0);
    if (enabled) {
      const counts = await app.locator('#table [data-label="Genome"] td').evaluateAll((cells) =>
        Object.fromEntries(cells.filter((c) => c.dataset.category !== "unmatched").map((c) => [c.dataset.category, Number(c.textContent.replaceAll(",", ""))])));
      for (const [key, value] of Object.entries(counts)) assert.equal(value, expected.genomeBackground_bp[key]);
    }
  }
  await app.setInputFiles("#chrom-sizes", { name: "fixture.chrom.sizes", mimeType: "text/plain", buffer: Buffer.from("F\t31000\n") });
  await app.click("#run");
  await app.waitForSelector('body[data-state="done"] #run:not([disabled])');
  // The extra [30000,31000) has no annotation: exactly 1000 more intergenic bp.
  assert.equal(Number((await app.textContent('#table [data-label="Genome"] [data-category="intergenic"]')).replaceAll(",", "")),
    expected.genomeBackground_bp.intergenic + 1000);
  await app.close();
  assert.deepEqual(env.uploads, []);
  assert.deepEqual(env.requests.filter((url) => new URL(url).origin !== env.base), []);
});
