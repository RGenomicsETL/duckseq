// The SQL pipeline against the hand-built fixture. expected.json was written by hand in
// peakwhere (seandavi/peakwhere, test/fixtures) before any code existed: it is the oracle.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { openBrowser } from "./browser.js";

const expected = JSON.parse(await readFile(new URL("./fixtures/expected.json", import.meta.url), "utf8"));
const CATEGORIES = ["promoter", "utr5", "utr3", "exon", "intron", "intergenic"];
const pick = (o) => Object.fromEntries(CATEGORIES.map((c) => [c, o[c]]));

let session;
let page;
before(async () => {
  session = await openBrowser();
  page = await session.newPage("/test/harness.html");
});
after(() => session.close());

const annotate = (request) => page.evaluate((r) => window.annotateUrls(r), request);
const fixture = (name) => `/test/fixtures/${name}`;
const peaks = [{ url: fixture("peaks.bed"), label: "peaks" }];

test("signed DuckHTS loads with unsigned extensions disallowed", async () => {
  const info = await page.evaluate(() => window.databaseInfo());
  assert.equal(info.unsigned, "false");
  assert.match(info.platform, /^wasm_/);
});

// ucsc.gtf: GTF 2.2 names its UTRs 5UTR and 3UTR, as UCSC exports do.
for (const annotation of ["fixture.gff3", "fixture.gtf", "ucsc.gtf"]) {
  test(`${annotation}: peak centres`, async () => {
    const { results } = await annotate({ annotation: fixture(annotation), peaks });
    const [r] = results;
    assert.deepEqual(r.counts, pick(expected.counts_centre));
    assert.equal(r.peaks.matched, expected.counts_centre.matched);
    assert.equal(r.peaks.unmatched, expected.counts_centre.unmatched);
    assert.deepEqual(r.unmatchedChroms, expected.counts_centre.unmatchedChroms);
  });

  test(`${annotation}: peak base pairs`, async () => {
    const { results } = await annotate({ annotation: fixture(annotation), peaks, settings: { mode: "bp" } });
    assert.deepEqual(results[0].counts, pick(expected.basepairs));
    assert.equal(results[0].matched, expected.basepairs.matched);
  });
}

test("fixture.gff3: genome background from ##sequence-region", async () => {
  const { background } = await annotate({ annotation: fixture("fixture.gff3"), peaks });
  assert.deepEqual(background.counts, pick(expected.genomeBackground_bp));
  assert.equal(background.total, expected.genomeBackground_bp.total);
});

test("fixture.gtf: no lengths, so no genome background", async () => {
  const { background, warnings } = await annotate({ annotation: fixture("fixture.gtf"), peaks });
  assert.equal(background, null);
  assert.ok(warnings.some((w) => /Genome bar is hidden/.test(w)));
});

test("chromosome names match without the chr prefix", async () => {
  const { results } = await annotate({
    annotation: fixture("fixture.gff3"),
    peaks: [{ url: fixture("peaks-nochr.bed"), label: "nochr" }],
  });
  assert.deepEqual(results[0].counts, pick(expected.counts_centre));
});

// seandavi/peakwhere#26: Ensembl names the type attributes *_biotype (GTF) or biotype (GFF3).
for (const annotation of ["ensembl.gtf", "ensembl.gff3"]) {
  test(`${annotation}: the protein-coding filter reads Ensembl biotypes`, async () => {
    const { results, warnings } = await annotate({
      annotation: fixture(annotation), peaks, settings: { proteinCodingOnly: true },
    });
    assert.deepEqual(results[0].counts, pick(expected.counts_centre));
    assert.ok(!warnings.some((w) => /every transcript was kept/.test(w)));
  });

  test(`${annotation}: without the filter, the lncRNA's promoter holds p17`, async () => {
    const { results } = await annotate({ annotation: fixture(annotation), peaks });
    const { promoter, intergenic } = expected.counts_centre;
    assert.deepEqual(results[0].counts, pick({ ...expected.counts_centre, promoter: promoter + 1, intergenic: intergenic - 1 }));
  });
}

for (const annotation of ["gene-types.gtf", "gencode.gtf"]) {
  test(`${annotation}: gene-line or per-line types filter transcripts on their own contig`, async () => {
    for (const proteinCodingOnly of [false, true]) {
      const { results, meta, warnings } = await annotate({
        annotation: fixture(annotation),
        peaks: [{ url: fixture("gene-types.bed"), label: "genes" }],
        settings: { promoterUpstream: 0, promoterDownstream: 0, proteinCodingOnly },
      });
      assert.deepEqual(results[0].counts, {
        promoter: 0, utr5: 0, utr3: 0, exon: proteinCodingOnly ? 2 : 4,
        intron: 0, intergenic: proteinCodingOnly ? 2 : 0,
      });
      assert.equal(meta.transcripts, proteinCodingOnly ? 2 : 4);
      assert.ok(!warnings.some((w) => /every transcript was kept/.test(w)));
    }
  });
}

// seandavi/peakwhere#27: a transcript_id reused on another chromosome is another transcript.
test("reused-id.gtf: each copy of a reused transcript_id keeps its own chromosome", async () => {
  const { results } = await annotate({
    annotation: fixture("reused-id.gtf"),
    peaks: [...peaks, { url: fixture("peaks-chrG.bed"), label: "chrG" }],
  });
  assert.deepEqual(results[0].counts, pick(expected.counts_centre));
  assert.deepEqual(results[1].counts, { promoter: 1, utr5: 1, utr3: 1, exon: 0, intron: 1, intergenic: 1 });
});

// The signed release's transport limit: https://github.com/RGenomicsETL/duckhts/issues/246.
// Fails when the signed build gains blob support, so its pin and warning can be reviewed.
test("signed DuckHTS cannot read registered files or blob: URLs", async () => {
  const probe = await page.evaluate((p) => window.probeLocalFile(p), fixture("peaks.bed"));
  assert.equal(probe.coreReader, 17, "DuckDB's own reader sees the registered file");
  assert.equal(probe.registered.ok, false);
  assert.match(probe.registered.error, /failed to open file/);
  assert.equal(probe.blobUrl.ok, false);
  assert.match(probe.blobUrl.error, /failed to open file/);
});

test("no request leaves the origin", () => {
  const foreign = session.requests.filter((u) => !u.startsWith(session.base));
  assert.deepEqual(foreign, []);
});
