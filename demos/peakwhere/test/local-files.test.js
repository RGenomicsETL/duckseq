import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { openBrowser } from "./browser.js";

const expected = JSON.parse(await readFile(new URL("./fixtures/expected.json", import.meta.url), "utf8"));
const categories = ["promoter", "utr5", "utr3", "exon", "intron", "intergenic"];
const want = (key) => Object.fromEntries(categories.map((c) => [c, expected[key][c]]));
const fixture = async (name, gzip = false) => ({
  name: name + (gzip ? ".gz" : ""), mimeType: "application/octet-stream",
  buffer: (gzip ? gzipSync : (x) => x)(await readFile(new URL(`./fixtures/${name}`, import.meta.url))),
});
let session;
let page;
before(async () => {
  session = await openBrowser();
  page = await session.newPage("/test/harness.html?duckhts=dev");
  await page.addInitScript(() => {
    window.localUrls = { created: [], revoked: [] };
    const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (file) => { const url = create(file); window.localUrls.created.push(url); return url; };
    URL.revokeObjectURL = (url) => { window.localUrls.revoked.push(url); revoke(url); };
  });
  await page.goto(`${session.base}/?duckhts=dev`);
  await page.waitForSelector("#run:not([disabled])", { timeout: 120_000 });
  await page.selectOption("#dataset", "local");
});
after(() => session.close());

async function run(state = "done") {
  await page.click("#run");
  await page.waitForSelector(`body[data-state="${state}"] #run:not([disabled])`, { timeout: 120_000 });
  assert.equal(await page.getAttribute("body", "data-state"), state, await page.textContent("#status"));
  const urls = await page.evaluate(() => window.localUrls);
  assert.equal(urls.created.length - urls.revoked.length, 3, "selected annotation and peaks retain their URLs");
}
async function counts(label) {
  return page.$$eval("#table tr[data-label]", (rows, label) => {
    const row = rows.find((r) => r.dataset.label === label);
    return Object.fromEntries([...row.querySelectorAll("td:not([data-category=unmatched])")]
      .map((td) => [td.dataset.category, Number(td.textContent.replaceAll(",", ""))]));
  }, label);
}

test("signed build reports the local-file limitation without an obscure query error", async () => {
  const signed = await session.newPage("/");
  await signed.waitForSelector("#run:not([disabled])");
  await signed.selectOption("#dataset", "local");
  assert.match(await signed.textContent("#local-status"), /signed DuckHTS build cannot read local files.*duckhts=dev/);
  await signed.click("#run");
  await signed.waitForSelector('body[data-state="error"]');
  assert.match(await signed.textContent("#status"), /signed DuckHTS build cannot read local files/);
  await signed.close();
});

for (const name of ["fixture.gff3", "fixture.gtf"]) {
  for (const gzip of [false, true]) {
    test(`local ${name}${gzip ? ".gz" : ""}: independent centre and bp counts, reruns`, async () => {
      await page.setInputFiles("#local-annotation", await fixture(name, gzip));
      await page.setInputFiles("#local-peaks", [await fixture("peaks.bed", gzip), await fixture("peaks-nochr.bed", gzip)]);
      await page.selectOption("#mode", "centre");
      await run();
      for (const peak of ["peaks.bed", "peaks-nochr.bed"]) assert.deepEqual(await counts(peak + (gzip ? ".gz" : "")), want("counts_centre"));
      if (name === "fixture.gff3") assert.deepEqual(await counts("Genome"), want("genomeBackground_bp"));
      else assert.match(await page.textContent("#warnings"), /Genome bar is hidden/);
      const urls = await page.evaluate(() => window.localUrls.created.length);
      await page.selectOption("#mode", "bp");
      await run();
      assert.equal(await page.evaluate(() => window.localUrls.created.length), urls, "redraw reuses URLs");
      assert.deepEqual(await counts("peaks.bed" + (gzip ? ".gz" : "")), want("basepairs"));
    });
  }
}

test("drag/drop gzip narrowPeak and broadPeak; filenames are text, not markup", async () => {
  await page.selectOption("#mode", "centre");
  for (const [target, files] of [
    ["#annotation-drop", [await fixture("fixture.gff3", true)]],
    ["#peaks-drop", [
      { name: "<img src=x>.narrowPeak.gz", buffer: gzipSync("chrF\t4500\t4600\tp\t10\t.\t5\t2\t1\t50\n") },
      { name: "broad.broadPeak", buffer: Buffer.from("chrF\t8600\t8700\tp\t10\t.\t5\t2\t1\n") },
    ]],
  ]) {
    await page.evaluate(({ target, files }) => {
      const dataTransfer = new DataTransfer();
      for (const { name, bytes } of files) dataTransfer.items.add(new File([new Uint8Array(bytes)], name));
      document.querySelector(target).dispatchEvent(new DragEvent("drop", { dataTransfer, bubbles: true }));
    }, { target, files: files.map((f) => ({ name: f.name, bytes: [...f.buffer] })) });
  }
  await run();
  assert.deepEqual(await counts("<img src=x>.narrowPeak.gz"), { promoter: 1, utr5: 0, utr3: 0, exon: 0, intron: 0, intergenic: 0 });
  assert.deepEqual(await counts("broad.broadPeak"), { promoter: 0, utr5: 0, utr3: 0, exon: 1, intron: 0, intergenic: 0 });
  assert.equal(await page.locator("#table img").count(), 0);
});

test("selected URLs survive errors; replacing, clearing and switching datasets revoke them", async () => {
  await page.setInputFiles("#local-annotation", { name: "broken.gtf.gz", mimeType: "application/gzip", buffer: Buffer.from([0x1f, 0x8b, 8, 0]) });
  await run("error");
  assert.equal(await page.locator("#output").isVisible(), false);
  await page.click("#clear-files");
  const urls = await page.evaluate(() => window.localUrls);
  assert.deepEqual(urls.revoked.sort(), urls.created.sort(), "clearing revokes every selected URL");
  assert.equal(await page.textContent("#annotation-name"), "No annotation selected");
  assert.equal(await page.textContent("#peak-names"), "No peak files selected");
  await page.setInputFiles("#local-annotation", await fixture("fixture.gff3"));
  await page.selectOption("#dataset", "fixture");
  await page.selectOption("#dataset", "local");
  assert.equal(await page.textContent("#annotation-name"), "No annotation selected");
});

test("localFileUrl has the npm contract and the dev build enables unsigned extensions explicitly", async () => {
  const harness = await session.newPage("/test/harness.html?duckhts=dev");
  assert.equal((await harness.evaluate(() => window.databaseInfo())).unsigned, "true");
  assert.equal(await harness.evaluate(async () => {
    const { localFileUrl } = await import("/src/duckhts-loader.js");
    try { localFileUrl("not a blob"); return false; } catch (e) { return e instanceof TypeError; }
  }), true);
  await harness.close();
});

test("no request leaves the origin and no local file is uploaded", () => {
  assert.deepEqual(session.requests.filter((url) => new URL(url).origin !== session.base), []);
  assert.deepEqual(session.uploads, []);
});
