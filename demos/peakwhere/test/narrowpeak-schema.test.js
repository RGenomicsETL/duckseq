import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { openBrowser } from "./browser.js";
import { narrowPeakReader } from "../src/peaks.js";

let browser, signed, dev, directory;
before(async () => {
  directory = await mkdtemp("test/.narrowpeak-");
  const source = await readFile("test/fixtures/summits.narrowPeak");
  await writeFile(`${directory}/peaks.gz`, gzipSync(source));
  // Two members, each containing ten rows. htslib must read both.
  await writeFile(`${directory}/members.gz`, Buffer.concat([gzipSync(source), gzipSync(source)]));
  browser = await openBrowser();
  signed = await browser.newPage("/test/harness.html");
  dev = await browser.newPage("/test/harness.html?duckhts=dev");
});
after(async () => {
  await browser?.close();
  await rm(directory, { recursive: true, force: true });
});

for (const build of ["signed", "dev"]) {
  test(`${build} declared narrowPeak schema: sequential plain, gzip, multi-member gzip and BGZF`, async () => {
    const page = build === "signed" ? signed : dev;
    for (const [path, n] of [["test/fixtures/summits.narrowPeak", 10], [`${directory}/peaks.gz`, 10],
      [`${directory}/members.gz`, 20], ["test/fixtures/summits.narrowPeak.bgz", 10]]) {
      for (const blob of build === "dev" ? [false, true] : [false]) {
        const url = await page.evaluate(async ({ path, blob }) => {
          const url = new URL(path, location.origin).href;
          return blob ? URL.createObjectURL(await (await fetch(url)).blob()) : url;
        }, { path, blob });
        try {
          const sql = `SELECT count(*) AS n, min(peak) AS lowest, max(peak) AS highest,
            min(signal_value) AS signal FROM ${narrowPeakReader(url)}`;
          assert.deepEqual(await page.evaluate((sql) => window.query(sql), sql),
            [{ n: BigInt(n), lowest: -2n, highest: 9999999999n, signal: 1.5 }]);
          const difference = `WITH bed AS (SELECT chrom, start, "end", name, block_count AS peak
              FROM read_bed('${url}', scan_mode := 'sequential')),
            declared AS (SELECT chrom, start, "end", name, peak FROM ${narrowPeakReader(url)})
            SELECT * FROM (TABLE bed EXCEPT ALL TABLE declared)
            UNION ALL (TABLE declared EXCEPT ALL TABLE bed)`;
          assert.deepEqual(await page.evaluate((sql) => window.query(sql), difference), []);
        } finally {
          if (blob) await page.evaluate((url) => URL.revokeObjectURL(url), url);
        }
      }
    }
  });
}

// Reader contract gaps tracked at https://github.com/RGenomicsETL/duckhts/issues/250.
// These fail when read_tabix can replace read_bed without changing rejection reports.
test("signed read_tabix limitation: BED track/browser lines become rejected coordinate rows", async () => {
  const path = `${directory}/headers.narrowPeak`;
  await writeFile(path, "track name=peaks\nbrowser position chr1:1-10\nchr1\t0\t10\ta\t1\t.\t1\t2\t3\t0\n");
  const url = `${browser.base}/${path}`;
  assert.deepEqual(await signed.evaluate((sql) => window.query(sql),
    `SELECT count(*) AS n FROM read_bed('${url}', scan_mode := 'sequential')`), [{ n: 1n }]);
  assert.deepEqual(await signed.evaluate((sql) => window.query(sql),
    `SELECT count(*) AS n, count(*) FILTER (WHERE start IS NULL) AS missing FROM ${narrowPeakReader(url)}`),
  [{ n: 3n, missing: 2n }]);
});

test("signed read_tabix limitation: overflowing BED integers become NULL instead of saturated integers", async () => {
  const path = `${directory}/overflow.narrowPeak`;
  await writeFile(path, "chr1\t0\t9223372036854775808\ta\t1\t.\t1\t2\t3\t0\n");
  const url = `${browser.base}/${path}`;
  assert.deepEqual(await signed.evaluate((sql) => window.query(sql),
    `SELECT "end" FROM read_bed('${url}', scan_mode := 'sequential')`), [{ end: 9223372036854775807n }]);
  assert.deepEqual(await signed.evaluate((sql) => window.query(sql),
    `SELECT "end" FROM ${narrowPeakReader(url)}`), [{ end: null }]);
});
