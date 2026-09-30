// Head-to-head: upstream peakwhere (bench/stage-upstream.mjs, pinned commit) in headless
// Chromium through its real file inputs, timing Run -> results and two setting changes.
// Run from the repository root: node bench/head-to-head-upstream.mjs <runs> <out.json>
// (Upstream re-runs 300 ms after a setting change; redraw times include that debounce.)
import { chromium } from "playwright-core";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";

const UP = resolve("bench/.cache/peakwhere-upstream");
const W2 = resolve("bench/.cache/W2");
const annotation = `${W2}/gencode.vM25.basic.annotation.gff3.gz`;
const peaks = ["CTCF_ENCFF714WDP", "DNase_ENCFF979ULB", "H3K27me3_ENCFF478UYW", "H3K36me3_ENCFF853BYO", "H3K4me3_ENCFF674JZY"]
  .map((p) => `${W2}/thymus_${p}.narrowPeak.gz`);
const runs = Number(process.argv[2] ?? 6);
const out = process.argv[3];

const server = spawn("node", ["scripts/serve.mjs", "--port", "8811"], { cwd: UP, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 800));
const browser = await chromium.launch({ args: ["--no-sandbox"] });
const results = [];
try {
  for (let i = 0; i < runs; i++) {
    const context = await browser.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    const offsite = [];
    page.on("request", (r) => { if (!r.url().startsWith("http://127.0.0.1:8811") && !r.url().startsWith("blob:") && !r.url().startsWith("data:")) offsite.push(r.url()); });
    await page.goto("http://127.0.0.1:8811/");
    await page.setInputFiles("#annotation-input", annotation);
    await page.setInputFiles("#peaks-input", peaks);
    await page.waitForSelector("#run:not([disabled])");
    const t0 = Date.now();
    await page.click("#run");
    await page.waitForSelector("#results:not([hidden])", { timeout: 600000 });
    const run = (Date.now() - t0) / 1000;
    const [dl] = await Promise.all([page.waitForEvent("download"), page.click(".pw-downloads button:has-text('CSV')")]);
    const csv = await readFile(await dl.path(), "utf8");
    // Re-draw on a setting change: centre -> base pairs, then promoter 1000 -> 2000.
    const redraw = {};
    for (const [name, act] of [["mode_bp", () => page.check("input[name=mode][value=bp]")],
                               ["promoter_2000", () => page.fill("#promoter-upstream", "2000")]]) {
      const before = await page.evaluate(() => document.querySelector("#results").innerHTML.length + ":" + document.querySelector("#results").textContent.slice(0, 2000));
      const t1 = Date.now();
      await act();
      await page.waitForFunction((b) => {
        const r = document.querySelector("#results");
        return !r.hidden && (r.innerHTML.length + ":" + r.textContent.slice(0, 2000)) !== b;
      }, before, { timeout: 120000, polling: 20 });
      redraw[name] = (Date.now() - t1) / 1000;
    }
    results.push({ i, warmup: i === 0, run, redraw, offsite, csv: i === 1 ? csv : undefined });
    console.log(JSON.stringify({ i, run, redraw, offsite: offsite.length }));
    await context.close();
  }
} finally {
  await browser.close();
  server.kill();
}
await writeFile(out, JSON.stringify(results, null, 1));
