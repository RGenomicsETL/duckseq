import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { openBrowser } from "./browser.js";

let browser, page;
before(async () => {
  browser = await openBrowser();
  page = await browser.newPage("/test/harness.html?duckhts=dev");
  await page.waitForFunction(() => !!window.runPeek);
});
after(() => browser.close());

test("Where and Peek share accepted rows, named rejections and isolated file errors", async () => {
  const got = await page.evaluate(async () => {
    const texts = [
      "chrF\t200\t210\ta\n F \t200\t210\tb\nchrF\t0\t0\nchrF\t5\t4\nchrF\t-1\t2\nchrF\tx\t2\nchrF\t1e3\t1001\nchrF\t1.5\t2\n \t1\t2\nchrF\t2147483647\t2147483648\n",
      "chr1\t0\t2\nchr1\t5\n",
      "chrF\t700\t701\tgood\n",
      "",
    ];
    const peaks = texts.map((text, i) => ({ label: String(i), url: URL.createObjectURL(new Blob([text])) }));
    try {
      const peek = await window.runPeek({ peaks });
      const where = await window.annotateUrls({ annotation: "/test/fixtures/fixture.gff3", peaks,
        settings: { promoterUpstream: 10, promoterDownstream: 5 } });
      const raw = await window.query("SELECT raw_chrom, ckey, name FROM peak WHERE fid = 0 AND reason IS NULL ORDER BY name");
      return { peek, where, raw };
    } finally {
      peaks.forEach((p) => URL.revokeObjectURL(p.url));
    }
  });
  assert.deepEqual(got.raw, [
    { raw_chrom: "chrF", ckey: "F", name: "a" },
    { raw_chrom: " F ", ckey: "F", name: "b" },
  ]);
  const rejected = [
    { reason: "coordinate exceeds the cgranges 32-bit range", n: 1 },
    { reason: "empty chromosome", n: 1 },
    { reason: "end before start", n: 1 },
    { reason: "negative coordinate", n: 1 },
    { reason: "non-integer or missing coordinate", n: 3 },
    { reason: "zero width", n: 1 },
  ];
  for (let i = 0; i < 4; i++) {
    const p = got.peek.results[i], w = got.where.results[i];
    assert.deepEqual(w.rejected, p.rejected);
    assert.equal(w.rejectedCount, p.rejectedCount);
    assert.equal(w.peaks.matched + w.peaks.unmatched, p.n);
    assert.equal(w.error, p.error);
  }
  assert.deepEqual(got.where.results[0].rejected, rejected);
  assert.equal(got.where.results[0].peaks.matched, 2);
  assert.match(got.where.results[1].error, /fewer than 3 tab-delimited fields/);
  assert.equal(got.where.results[1].drawn, false);
  assert.equal(got.where.results[2].peaks.matched, 1);
  assert.equal(got.where.results[3].drawn, false);
  assert.ok(got.where.warnings.some((w) => w.includes("zero width")));
  assert.ok(got.where.warnings.some((w) => w.includes("could not read file")));
});
