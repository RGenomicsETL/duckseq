// Actual app submit -> rendered results, including its session cache on redraws.
// node bench/head-to-head-ours.mjs <runs> <out.json>
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { openBrowser } from "../test/browser.js";
import { assertW2 } from "./w2-counts.mjs";

const runs = Number(process.argv[2] ?? 6);
const out = process.argv[3];
const commit = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const dirty = !!execFileSync("git", ["diff", "HEAD", "--", "src", "bench", "scripts", "index.html"], { encoding: "utf8" }).trim();
const peaks = ["CTCF_ENCFF714WDP", "DNase_ENCFF979ULB", "H3K27me3_ENCFF478UYW", "H3K36me3_ENCFF853BYO", "H3K4me3_ENCFF674JZY"];
const results = [];
for (let i = 0; i < runs; i++) {
  const session = await openBrowser();
  try {
    const page = await session.newPage("/");
    await page.waitForSelector("#run:not([disabled])", { timeout: 120_000 });
    const startup = await page.evaluate(() => performance.now() / 1000);
    await page.evaluate(async (peaks) => {
      const { DATASETS } = await import("/src/app.js");
      DATASETS.W2 = {
        annotations: { GENCODE: "bench/.cache/W2/gencode.vM25.basic.annotation.gff3.gz" },
        peaks: Object.fromEntries(peaks.map((p) => [p.split("_")[0], `bench/.cache/W2/thymus_${p}.narrowPeak.gz`])),
      };
      document.querySelector("#dataset").add(new Option("W2", "W2"));
    }, peaks);
    await page.selectOption("#dataset", "W2");
    async function run() {
      return page.evaluate(() => new Promise((resolve, reject) => {
        const start = performance.now();
        delete document.body.dataset.state;
        const observer = new MutationObserver(() => {
          const state = document.body.dataset.state;
          if (!state) return;
          observer.disconnect();
          if (state === "error") reject(Error(document.querySelector("#status").textContent));
          else resolve((performance.now() - start) / 1000);
        });
        observer.observe(document.body, { attributes: true, attributeFilter: ["data-state"] });
        document.querySelector("#form").requestSubmit();
      }));
    }
    const first = await run();
    const counts = await page.$$eval("#table tr[data-label]", (rows) => Object.fromEntries(rows
      .filter((r) => r.dataset.label !== "Genome")
      .map((r) => [r.dataset.label, Object.fromEntries([...r.querySelectorAll("td:not([data-category=unmatched])")]
        .map((td) => [td.dataset.category, Number(td.textContent.replaceAll(",", ""))]))])));
    assertW2(counts);
    await page.selectOption("#mode", "bp");
    const mode_bp = await run();
    await page.fill("#up", "2000");
    const promoter_2000 = await run();
    const offsite = session.requests.filter((u) => !u.startsWith(session.base));
    assert.deepEqual(offsite, []);
    const r = { i, warmup: i === 0, commit, dirty, startup, run: first,
      redraw: { mode_bp, promoter_2000 }, counts, offsite };
    results.push(r);
    console.log(JSON.stringify({ i, startup, run: first, redraw: r.redraw, offsite: offsite.length }));
  } finally {
    await session.close();
  }
}
await writeFile(out, JSON.stringify(results, null, 1) + "\n");
