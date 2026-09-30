import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

test("development staging rejects a changed artifact before writing vendor files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "duckpeakwhere-stage-"));
  try {
    const manifest = await readFile(new URL("../duckhts-dev-manifest.json", import.meta.url));
    await writeFile(join(directory, "duckhts-dev-manifest.json"), manifest);
    const first = Object.values(JSON.parse(manifest).files)[0];
    await mkdir(join(directory, "artifacts", first.artifact), { recursive: true });
    await writeFile(join(directory, "artifacts", first.artifact, "duckhts.duckdb_extension.wasm"), "untrusted");
    const result = spawnSync(process.execPath, [new URL("../scripts/stage-duckhts-dev.mjs", import.meta.url).pathname, "artifacts"], {
      cwd: directory, encoding: "utf8",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /sha256 .* manifest says/);
    await assert.rejects(access(join(directory, "vendor")), { code: "ENOENT" });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
