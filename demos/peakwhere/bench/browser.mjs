// One fresh page per invocation. Keep its same-origin server alive for native replay.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile, rename } from "node:fs/promises";
import { openBrowser } from "../test/browser.js";
import { assertW2 } from "./w2-counts.mjs";

const [input, output] = process.argv.slice(2);
const request = JSON.parse(await readFile(input, "utf8"));
const manifest = JSON.parse(await readFile("duckhts-manifest.json", "utf8"));
const wasmHash = createHash("sha256").update(await readFile(
  "vendor/duckhts/wasm_eh/duckhts.duckdb_extension.wasm")).digest("hex");
assert.equal(wasmHash, manifest.files.wasm_eh);
const session = await openBrowser();
try {
  const page = await session.newPage("/bench/harness.html");
  request.annotation = `${session.base}/${request.annotation}`;
  request.peaks = request.peaks.map(({ url, label }) => ({ url: `${session.base}/${url}`, label }));
  const result = await page.evaluate(async (request) => {
    const { openDatabase } = await import("/src/db.js");
    const { annotate } = await import("/src/annotate.js");
    const { db, conn, platform, version } = await openDatabase();
    const info = (await conn.query(`SELECT current_setting('allow_unsigned_extensions') AS unsigned,
      current_setting('threads') AS threads,
      (SELECT extension_version FROM duckdb_extensions() WHERE extension_name='duckhts') AS duckhts`)).toArray()[0].toJSON();
    const trace = [];
    const marks = {};
    let phase;
    const measured = { query: async (sql) => {
      trace.push({ phase, sql });
      return conn.query(sql);
    } };
    const result = await annotate(measured, request, { onPhase: (name) => {
      marks[name] = performance.now();
      phase = name;
    } });
    await conn.close();
    await db.terminate();
    return { result, trace, version, platform, duckhts: info.duckhts,
      unsigned: info.unsigned, threads: Number(info.threads),
      seconds: { partition: (marks.count - marks.partition) / 1000,
        count: (marks.done - marks.count) / 1000, total: (marks.done - marks.partition) / 1000 } };
  }, request);
  assert.equal(result.platform, "wasm_eh");
  assert.equal(result.threads, 1);
  assert.equal(result.unsigned, false);
  result.duckhts_sha256 = wasmHash;
  result.duckhts_release = manifest.duckhts;
  assert.deepEqual(session.requests.filter((url) => !url.startsWith(session.base)), []);
  result.sql_sha256 = createHash("sha256").update(JSON.stringify(result.trace)).digest("hex");
  result.chromium = page.context().browser().version();
  result.counts_centre = Object.fromEntries(result.result.results.map((r) => [r.label, r.counts]));
  result.unmatched = Object.fromEntries(result.result.results.map((r) => [r.label, r.peaks.unmatched]));
  if (request.annotation.includes("/W2/")) assertW2(result.counts_centre);
  result.request = request;
  await writeFile(`${output}.tmp`, JSON.stringify(result));
  await rename(`${output}.tmp`, output);
  await new Promise((resolve) => { process.stdin.once("data", resolve); process.stdin.once("end", resolve); });
  process.stdin.destroy();
} finally {
  await session.close();
}
