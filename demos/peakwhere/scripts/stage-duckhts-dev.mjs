// Stage only the pinned unsigned wasm artifacts, for the explicit ?duckhts=dev switch.
// An optional directory argument uses an archived `gh run download` tree offline.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const manifest = JSON.parse(await readFile("duckhts-dev-manifest.json", "utf8"));
const local = process.argv[2];
const directory = local ?? await mkdtemp(join(tmpdir(), "duckhts-dev-"));
try {
  if (!local) {
    execFileSync("gh", ["run", "download", String(manifest.source.run), "-R", manifest.source.repository,
      ...Object.values(manifest.files).flatMap(({ artifact }) => ["-n", artifact]), "-D", directory], { stdio: "inherit" });
  }
  const verified = [];
  for (const [platform, { artifact, sha256 }] of Object.entries(manifest.files)) {
    const bytes = await readFile(join(directory, artifact, "duckhts.duckdb_extension.wasm"));
    const actual = createHash("sha256").update(bytes).digest("hex");
    if (actual !== sha256) throw new Error(`${platform}: sha256 ${actual}, manifest says ${sha256}`);
    verified.push({ platform, bytes });
  }
  for (const { platform, bytes } of verified) {
    await mkdir(`vendor/duckhts-dev/${platform}`, { recursive: true });
    await writeFile(`vendor/duckhts-dev/${platform}/duckhts.duckdb_extension.wasm`, bytes);
    console.log(`${platform}: ${bytes.length} bytes, sha256 ok (UNSIGNED, run ${manifest.source.run})`);
  }
} finally {
  if (!local) await rm(directory, { recursive: true, force: true });
}
