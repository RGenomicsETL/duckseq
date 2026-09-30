import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

let env, page;
before(async () => {
  env = await openBrowser();
  page = await env.newPage("/test/harness.html");
});
after(() => env.close());
const midpoint = { promoter: 2, utr5: 0, utr3: 0, exon: 0, intron: 0, intergenic: 8 };
const summit = { promoter: 0, utr5: 0, utr3: 0, exon: 3, intron: 0, intergenic: 7 };
const bp = { promoter: 2, utr5: 0, utr3: 0, exon: 118, intron: 0, intergenic: 280 };

test("narrowPeak summit offsets include zero and exclude the end; invalid offsets fall back", async () => {
  const runs = await page.evaluate(async () => {
    await window.clearSession();
    const base = `${location.origin}/test/fixtures/`;
    const request = { annotation: `${base}gene-types.gtf`,
      peaks: [{ url: `${base}summits.narrowPeak`, label: "summits" }],
      settings: { promoterUpstream: 0, promoterDownstream: 0 } };
    const off = await window.runSession("where", request);
    window.takeQueries();
    request.settings.useSummits = true;
    const on = await window.runSession("where", request);
    request.settings.mode = "bp";
    const bp = await window.runSession("where", request);
    request.settings.mode = "centre";
    request.settings.useSummits = false;
    const again = await window.runSession("where", request);
    const sql = window.takeQueries().join("\n");
    request.settings.useSummits = true;
    const formats = [];
    for (const filename of ["peaks.bed", "peaks.broadPeak", "peaks.narrowPeak.gz"]) {
      request.peaks[0].filename = filename;
      formats.push(await window.runSession("where", request));
    }
    return { off, on, bp, again, formats, sql };
  });
  assert.deepEqual(runs.off.results[0].counts, midpoint);
  assert.deepEqual(runs.on.results[0].counts, summit);
  assert.equal(runs.on.results[0].summitFallbacks, 5);
  assert.match(runs.on.warnings.join("\n"), /5 peak\(s\).*midpoint/);
  assert.deepEqual(runs.bp.results[0].counts, bp);
  assert.equal(runs.bp.results[0].summitFallbacks, 0);
  assert.doesNotMatch(runs.bp.warnings.join("\n"), /fell back to the midpoint/);
  assert.deepEqual(runs.again.results[0].counts, midpoint);
  assert.doesNotMatch(runs.sql, /read_bed|read_gtf|read_hts_header|CREATE OR REPLACE TEMP TABLE/);
  for (const r of runs.formats.slice(0, 2)) {
    assert.deepEqual(r.results[0].counts, midpoint);
    assert.equal(r.results[0].summitFallbacks, 0);
  }
  assert.deepEqual(runs.formats[2].results[0].counts, summit);
});

test("unmatched chromosomes do not contribute summit fallbacks", async () => {
  const result = await page.evaluate(async () => {
    await window.clearSession();
    const base = `${location.origin}/test/fixtures/`;
    return window.runSession("where", { annotation: `${base}gene-types.gtf`,
      peaks: [{ url: `${base}summits-unmatched.narrowPeak`, label: "summits" }],
      settings: { promoterUpstream: 0, promoterDownstream: 0, useSummits: true } });
  });
  assert.deepEqual(result.results[0].counts, summit);
  assert.equal(result.results[0].peaks.unmatched, 1);
  assert.equal(result.results[0].summitFallbacks, 5);
  assert.match(result.warnings.join("\n"), /5 peak\(s\).*midpoint/);
});

test("valid narrowPeak summits do not emit a fallback warning", async () => {
  const result = await page.evaluate(async () => {
    await window.clearSession();
    const base = `${location.origin}/test/fixtures/`;
    return window.runSession("where", { annotation: `${base}gene-types.gtf`,
      peaks: [{ url: `${base}summits-valid.narrowPeak`, label: "valid" }],
      settings: { promoterUpstream: 0, promoterDownstream: 0, useSummits: true } });
  });
  assert.deepEqual(result.results[0].counts, { ...summit, exon: 2, intergenic: 0 });
  assert.equal(result.results[0].summitFallbacks, 0);
  assert.doesNotMatch(result.warnings.join("\n"), /fell back to the midpoint/);
});

test("signed read_bed exposes narrowPeak column 10 as block_count", async () => {
  const offsets = await page.evaluate(async () => (await window.query(
    `SELECT block_count FROM read_bed('${location.origin}/test/fixtures/summits.narrowPeak', scan_mode := 'sequential')`
  )).map((r) => r.block_count));
  assert.deepEqual(offsets, [0n, 9n, 10n, -1n, 40n, -2n, null, 0n, 39n, 9999999999n]);
});

test("local gzip narrowPeak keeps its format through blob URLs and reports summit fallbacks", async () => {
  const app = await env.newPage("/?duckhts=dev");
  await app.waitForFunction(() => !document.querySelector("#run").disabled);
  await app.selectOption("#dataset", "local");
  await app.setInputFiles("#local-annotation", "test/fixtures/gene-types.gtf");
  const buffer = gzipSync(await readFile("test/fixtures/summits.narrowPeak"));
  await app.setInputFiles("#local-peaks", { name: "summits.narrowPeak.gz", mimeType: "application/gzip", buffer });
  await app.fill("#up", "0");
  await app.fill("#down", "0");
  assert.equal(await app.isChecked("#summits"), false);
  for (const useSummits of [true, false]) {
    await app.locator("#summits").setChecked(useSummits);
    await app.click("#run");
    await app.waitForFunction(() => document.body.dataset.state === "done");
    const counts = await app.locator('#table [data-label="summits.narrowPeak.gz"] td').evaluateAll((cells) =>
      Object.fromEntries(cells.filter((c) => c.dataset.category !== "unmatched").map((c) => [c.dataset.category, Number(c.textContent)])));
    assert.deepEqual(counts, useSummits ? summit : midpoint);
    assert.equal(/5 peak\(s\).*midpoint/.test(await app.textContent("#warnings")), useSummits);
  }
  await app.close();
});
