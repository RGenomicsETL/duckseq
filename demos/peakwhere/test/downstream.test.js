import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

let env, page;
before(async () => {
  env = await openBrowser();
  page = await env.newPage("/test/harness.html");
});
after(async () => { await env?.close(); });

const counts = (exon, intron, downstream, intergenic, promoter) =>
  ({ promoter, utr5: 0, utr3: 0, exon, intron, downstream, intergenic });

test("post-TES windows respect strand, boundaries and priority in both counting modes", async () => {
  for (const mode of ["centre", "bp"]) {
    const result = await page.evaluate(({ base, mode }) => window.annotateUrls({
      annotation: `${base}/test/fixtures/downstream.gff3`,
      peaks: [{ url: `${base}/test/fixtures/downstream.bed`, label: "TES" }],
      settings: { promoterUpstream: 0, promoterDownstream: 0, downstreamEnabled: true, downstreamWindow: 100, mode },
    }), { base: env.base, mode });
    assert.deepEqual(result.results[0].counts, mode === "centre" ? counts(6, 5, 6, 1, 2) : counts(53, 94, 76, 1, 3));
    assert.deepEqual(result.background.counts, counts(106, 200, 110, 600, 4));
  }
});

test("cached downstream settings toggle and resize without rereading files", async () => {
  const runs = await page.evaluate(async (base) => {
    await window.clearSession();
    const request = {
      annotation: `${base}/test/fixtures/downstream.gff3`,
      peaks: [{ url: `${base}/test/fixtures/downstream.bed`, label: "TES" }],
      settings: { promoterUpstream: 0, promoterDownstream: 0 },
    };
    const off = await window.runSession("where", request);
    window.takeQueries();
    request.settings.downstreamEnabled = true;
    request.settings.downstreamWindow = 100;
    const on = await window.runSession("where", request);
    request.settings.downstreamWindow = 10;
    const small = await window.runSession("where", request);
    request.settings.downstreamWindow = 0;
    const zero = await window.runSession("where", request);
    request.settings.downstreamEnabled = false;
    const again = await window.runSession("where", request);
    return { off, on, small, zero, again, sql: window.takeQueries().join("\n") };
  }, env.base);
  assert.doesNotMatch(runs.sql, /read_bed|read_gff|read_gtf|read_hts_header/);
  const off = { promoter: 2, utr5: 0, utr3: 0, exon: 6, intron: 5, intergenic: 7 };
  assert.deepEqual(runs.off.results[0].counts, off);
  assert.deepEqual(runs.again.results[0].counts, off);
  assert.deepEqual(runs.on.results[0].counts, counts(6, 5, 6, 1, 2));
  assert.deepEqual(runs.small.results[0].counts, counts(6, 5, 5, 2, 2));
  assert.deepEqual(runs.small.background.counts, counts(106, 200, 40, 670, 4));
  assert.deepEqual(runs.zero.results[0].counts, counts(6, 5, 0, 7, 2));
});

test("Where displays and downloads only enabled categories", async () => {
  const app = await env.newPage("/?duckhts=dev");
  await app.waitForFunction(() => !document.querySelector("#run").disabled);
  await app.selectOption("#dataset", "local");
  await app.setInputFiles("#local-annotation", "test/fixtures/downstream.gff3");
  await app.setInputFiles("#local-peaks", "test/fixtures/downstream.bed");
  await app.fill("#up", "0");
  await app.fill("#down", "0");
  for (const enabled of [false, true, false]) {
    await app.locator("#downstream-enabled").setChecked(enabled);
    await app.fill("#downstream-window", "100");
    await app.click("#run");
    await app.waitForFunction(() => document.body.dataset.state === "done");
    assert.equal(await app.locator('#table [data-category="downstream"]').count(), enabled ? 2 : 0);
    assert.equal((await app.textContent("#summary")).includes("Downstream"), enabled);
    if (enabled) assert.equal(await app.textContent('#table [data-label="downstream.bed"] [data-category="downstream"]'), "6");
    for (const [button, suffix] of [["#where-tsv", "tsv"], ["#where-svg", "svg"]]) {
      const pending = app.waitForEvent("download");
      await app.click(button);
      const download = await pending;
      assert.equal(download.suggestedFilename(), `where-${suffix === "tsv" ? "summary" : "chart"}.${suffix}`);
      const text = await readFile(await download.path(), "utf8");
      assert.equal(text.includes("Downstream"), enabled);
      if (suffix === "tsv" && enabled) assert.match(text, /downstream.bed\t2\t0\t0\t6\t5\t6\t1\t0/);
    }
  }
  await app.close();
});
