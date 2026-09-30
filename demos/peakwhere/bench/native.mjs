// Replay the app's captured SQL, byte for byte, in a fresh signed-only DuckDB CLI.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { CATEGORIES } from "../src/annotate.js";
import { assertW2 } from "./w2-counts.mjs";

const [input, engine, output] = process.argv.slice(2);
assert.ok(["native-1t", "native-nt"].includes(engine));
const { trace, request, sql_sha256 } = JSON.parse(await readFile(input, "utf8"));
assert.equal(createHash("sha256").update(JSON.stringify(trace)).digest("hex"), sql_sha256);
const extension = resolve("bench/.cache/native/duckhts.duckdb_extension").replaceAll("'", "''");
const sql = [
  ".mode json", ".timer off", "SET allow_unsigned_extensions=false;", "SET autoinstall_known_extensions=false;",
  `LOAD '${extension}';`, ...(engine === "native-1t" ? ["SET threads=1;"] : []),
  ".print INFO", `SELECT version() AS version, current_setting('threads') AS threads,
    current_setting('allow_unsigned_extensions')::BOOLEAN AS unsigned,
    (SELECT extension_version FROM duckdb_extensions() WHERE extension_name='duckhts') AS duckhts;`, ".timer on",
  ...trace.flatMap(({ sql }, i) => [`.print STATEMENT_${i}`, `${sql}${/;\s*$/.test(sql) ? "" : ";"}`]),
  ".print FINISHED",
].join("\n");
const rssFile = `${output}.time`;
const start = performance.now();
const proc = spawnSync("/usr/bin/time", ["-v", "-o", rssFile, "duckdb", "-batch", "-bail", ":memory:"],
  { input: sql, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: 600_000 });
const process_wall = (performance.now() - start) / 1000;
await writeFile(`${output}.stdout`, proc.stdout ?? "");
await writeFile(`${output}.stderr`, proc.stderr ?? "");
if (proc.error) throw proc.error;
if (proc.status !== 0) throw new Error(`DuckDB exit ${proc.status}: ${proc.stderr}`);
const blocks = proc.stdout.split(/^STATEMENT_\d+\r?\n/m);
const info = JSON.parse(blocks.shift().split("INFO\n")[1].split("Run Time")[0].trim())[0];
// The CLI JSON mode serializes BOOLEAN values as strings.
assert.equal(info.unsigned, "false");
info.unsigned = false;
assert.equal(info.duckhts, "1.5.2");
if (engine === "native-1t") assert.equal(info.threads, 1);
assert.equal(blocks.length, trace.length);
const seconds = { partition: 0, count: 0, total: 0, process_wall };
const counts_centre = {};
const unmatched = {};
const statements = [];
let peak = 0;
for (const [i, block] of blocks.entries()) {
  const time = /Run Time \(s\): real ([\d.]+)/.exec(block);
  assert.ok(time, `No DuckDB statement timer at ${i}`);
  const elapsed = Number(time[1]);
  seconds[trace[i].phase] += elapsed;
  statements.push({ phase: trace[i].phase, seconds: elapsed });
  const text = block.slice(0, time.index).trim();
  // Count queries return non-empty priority/n rows. Other output includes CLI
  // diagnostics and its malformed JSON representation of empty result sets.
  const rows = text.startsWith('[{"priority":') ? JSON.parse(text) : [];
  if (rows.some((r) => r.priority === -2)) {
    const label = request.peaks[peak++].label;
    const counts = Object.fromEntries(CATEGORIES.map((c) => [c, 0]));
    for (const r of rows) if (r.priority > 0) counts[CATEGORIES[r.priority - 1]] += Number(r.n ?? 0);
    counts_centre[label] = counts;
    unmatched[label] = Number(rows.find((r) => r.priority === -2).n);
  }
}
assert.equal(peak, request.peaks.length);
if (request.annotation.includes("/W2/")) assertW2(counts_centre);
seconds.total = seconds.partition + seconds.count;
const memory = await readFile(rssFile, "utf8");
const rss_kb = Number(/Maximum resident set size \(kbytes\): (\d+)/.exec(memory)[1]);
await writeFile(output, JSON.stringify({ ...info, seconds, rss_kb, counts_centre, unmatched,
  sql_sha256, statements, time_v: memory, stdout: proc.stdout, stderr: proc.stderr }));
