// The page end to end: pick a bundled dataset, press the button, read the table.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

const expected = JSON.parse(await readFile(new URL("./fixtures/expected.json", import.meta.url), "utf8"));
const CATEGORIES = ["promoter", "utr5", "utr3", "exon", "intron", "intergenic"];

// Peak-centre counts from test/oracle.R, an independent brute-force implementation.
const thymus = JSON.parse(await readFile(new URL("./fixtures/thymus-expected.json", import.meta.url), "utf8"));

// Peak counts per file, from examples/README.md (counted when the files were cut).
const EXAMPLE_PEAKS = { H3K4me3: 859, H3K36me3: 2855, H3K27me3: 605, CTCF: 706, DNase: 2195 };

let session;
let page;
before(async () => {
  session = await openBrowser();
  page = await session.newPage("/");
  await page.waitForSelector("#run:not([disabled])", { timeout: 120_000 });
});
after(() => session.close());

async function runAndReadTable() {
  await page.evaluate(() => delete document.body.dataset.state);
  await page.click("#run");
  await page.waitForSelector("body[data-state]", { timeout: 120_000 });
  const state = await page.getAttribute("body", "data-state");
  assert.equal(state, "done", await page.textContent("#status"));
  return page.$$eval("#table tr[data-label]", (rows) =>
    Object.fromEntries(
      rows.map((r) => [
        r.dataset.label,
        Object.fromEntries([...r.querySelectorAll("td")].map((td) => [td.dataset.category, td.textContent])),
      ]),
    ),
  );
}

const asNumbers = (row) => Object.fromEntries(CATEGORIES.map((c) => [c, Number(row[c].replaceAll(",", ""))]));

test("fixture: the table matches the hand-worked answers", async () => {
  await page.selectOption("#dataset", "fixture");
  const table = await runAndReadTable();
  const want = Object.fromEntries(CATEGORIES.map((c) => [c, expected.counts_centre[c]]));
  assert.deepEqual(asNumbers(table.peaks), want);
  assert.deepEqual(asNumbers(table["peaks-nochr"]), want);
  assert.deepEqual(asNumbers(table.Genome), Object.fromEntries(CATEGORIES.map((c) => [c, expected.genomeBackground_bp[c]])));
});

test("thymus chr19: counts match the independent oracle, and a chart is drawn", async () => {
  await page.selectOption("#dataset", "thymus");
  const table = await runAndReadTable();
  for (const [label, n] of Object.entries(EXAMPLE_PEAKS)) {
    const counted = Object.values(asNumbers(table[label])).reduce((a, b) => a + b, 0);
    assert.equal(counted + Number(table[label].unmatched), n, label);
    assert.deepEqual(asNumbers(table[label]), thymus.counts_centre[label], label);
  }
  // H3K4me3 marks active promoters: it should be the most promoter-rich file.
  const share = (label) => asNumbers(table[label]).promoter / EXAMPLE_PEAKS[label];
  for (const label of Object.keys(EXAMPLE_PEAKS)) assert.ok(share("H3K4me3") >= share(label), label);
  assert.ok(await page.$("#chart svg"));
});

test("no request leaves the origin", () => {
  assert.deepEqual(session.requests.filter((u) => !u.startsWith(session.base)), []);
});
