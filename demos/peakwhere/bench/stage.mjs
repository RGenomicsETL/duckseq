// Build-time downloads only. Hash the compressed upstream bytes on every stage.
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { gunzipSync } from "node:zlib";

const manifest = JSON.parse(await readFile("bench/manifest.json", "utf8"));
const workload = process.argv[2] ?? "W1";
if (!["W1", "W2"].includes(workload)) throw new Error("Usage: node bench/stage.mjs W1|W2");
const files = [manifest.native, ...(workload === "W2" ? manifest.W2 : [])];
for (const file of files) {
  let bytes;
  try {
    bytes = await readFile(file.path);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    const response = await fetch(file.url, { signal: AbortSignal.timeout(300_000) });
    if (!response.ok) throw new Error(`${file.url}: HTTP ${response.status}`);
    bytes = Buffer.from(await response.arrayBuffer());
  }
  const actual = createHash("sha256").update(bytes).digest("hex");
  if (actual !== file.sha256) throw new Error(`${file.url}: sha256 ${actual}, expected ${file.sha256}`);
  await mkdir(dirname(file.path), { recursive: true });
  await writeFile(file.path, bytes);
  if (file === manifest.native) {
    await writeFile(file.path.slice(0, -3), gunzipSync(bytes));
  }
  console.log(`${file.path}: ${bytes.length} bytes, sha256 ${actual} verified`);
}
