// Sequential W2 native replay, exact-count gated, plus the deployed browser's capabilities.
// node bench/threading.mjs <measured-runs> <out.json>
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, writeFile, rm, access } from "node:fs/promises";
import { tmpdir, cpus } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { openBrowser } from "../test/browser.js";
import { assertW2 } from "./w2-counts.mjs";

const n = Number(process.argv[2] ?? 3), out = process.argv[3];
const dir = await mkdtemp(join(tmpdir(), "peakpeek-threads-"));
const peaks = ["CTCF_ENCFF714WDP", "DNase_ENCFF979ULB", "H3K27me3_ENCFF478UYW", "H3K36me3_ENCFF853BYO", "H3K4me3_ENCFF674JZY"];
let capture;
try {
  const browser = await openBrowser();
  let wasm;
  try {
    const page = await browser.newPage("/bench/harness.html");
    wasm = await page.evaluate(async () => {
      const duckdb = await import("/vendor/duckdb.js");
      const { openDatabase } = await import("/src/db.js");
      const { db, conn, platform, version } = await openDatabase();
      const settings = (await conn.query(`SELECT current_setting('threads')::INTEGER AS threads,
        current_setting('allow_unsigned_extensions') AS unsigned`)).toArray()[0].toJSON();
      const result = { platform, version, ...settings, crossOriginIsolated,
        sharedArrayBuffer: typeof SharedArrayBuffer !== "undefined", features: await duckdb.getPlatformFeatures() };
      await conn.close();
      await db.terminate();
      return result;
    });
    wasm.offsite = browser.requests.filter((url) => !url.startsWith(browser.base));
    assert.deepEqual(wasm.offsite, []);
    assert.equal(wasm.unsigned, false);
  } finally { await browser.close(); }
  const request = { annotation: "bench/.cache/W2/gencode.vM25.basic.annotation.gff3.gz",
    peaks: peaks.map((p) => ({ label: p.split("_")[0], url: `bench/.cache/W2/thymus_${p}.narrowPeak.gz` })) };
  const input = join(dir, "request.json"), traceFile = join(dir, "trace.json");
  await writeFile(input, JSON.stringify(request));
  capture = spawn(process.execPath, ["bench/browser.mjs", input, traceFile], { stdio: ["pipe", "inherit", "inherit"] });
  const captureDone = once(capture, "exit");
  for (let i = 0; ; i++) {
    try { await access(traceFile); break; } catch {
      if (capture.exitCode !== null || i > 1200) throw Error("SQL trace capture failed or timed out");
      await delay(100);
    }
  }
  const trace = JSON.parse(await readFile(traceFile, "utf8"));
  assertW2(trace.counts_centre);
  const results = [];
  for (let i = 0; i <= n; i++) {
    // Alternate order to distribute any residual warm-cache/order effects.
    for (const engine of i % 2 ? ["native-nt", "native-1t"] : ["native-1t", "native-nt"]) {
      const file = join(dir, `${engine}-${i}.json`);
      const child = spawn(process.execPath, ["bench/native.mjs", traceFile, engine, file], { stdio: "inherit" });
      const [code] = await once(child, "exit");
      assert.equal(code, 0);
      const r = JSON.parse(await readFile(file, "utf8"));
      assertW2(r.counts_centre);
      const { stdout, stderr, time_v, ...summary } = r;
      results.push({ i, warmup: i === 0, engine, ...summary });
      console.log(JSON.stringify({ i, engine, threads: r.threads, seconds: r.seconds.total, rss_kb: r.rss_kb }));
    }
  }
  capture.stdin.end("done\n");
  await captureDone;
  await writeFile(out, JSON.stringify({
    commit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    cpu: cpus()[0].model, logical_cpus: cpus().length, wasm,
    sql_sha256: trace.sql_sha256, results,
  }, null, 1) + "\n");
} finally {
  if (capture?.exitCode === null) capture.kill();
  await rm(dir, { recursive: true, force: true });
}
