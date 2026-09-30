// Whole-genome ENCODE examples for PeakPeek's documented checks (SPEC §2).
// Reuse the benchmark's pinned sources; an optional directory supplies offline copies.
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const { W2 } = JSON.parse(await readFile("bench/manifest.json", "utf8"));
const source = process.argv[2];
const verified = [];
for (const file of W2.filter((f) => f.path.endsWith(".narrowPeak.gz"))) {
  const name = basename(file.path);
  let bytes;
  if (source) bytes = await readFile(join(source, name));
  else {
    const response = await fetch(file.url);
    if (!response.ok) throw new Error(`${response.status} ${file.url}`);
    bytes = Buffer.from(await response.arrayBuffer());
  }
  const hash = createHash("sha256").update(bytes).digest("hex");
  if (hash !== file.sha256) throw new Error(`${name}: sha256 ${hash}, manifest says ${file.sha256}`);
  verified.push({ name, bytes });
}
await mkdir("vendor/peek-examples", { recursive: true });
for (const { name, bytes } of verified) {
  await writeFile(`vendor/peek-examples/${name}`, bytes);
  console.log(`${name}: ${bytes.length} bytes, sha256 ok`);
}
