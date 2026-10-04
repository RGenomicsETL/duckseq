import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { serve } from "../scripts/serve.mjs";

test("server confines requests to its root and survives malformed escapes", async (t) => {
  const temp = await mkdtemp(path.join(tmpdir(), "peakwhere-server-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const root = path.join(temp, "app");
  await mkdir(root);
  await mkdir(`${root}-other`);
  await writeFile(path.join(root, "index.html"), "inside");
  await writeFile(path.join(`${root}-other`, "secret.txt"), "outside");
  const server = await serve(root);
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(`${url}/..%2fapp-other/secret.txt`)).status, 403);
  assert.equal((await fetch(`${url}/%`)).status, 400);
  const response = await fetch(`${url}/`);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "inside");
  const range = await fetch(`${url}/index.html`, { headers: { Range: "bytes=1-3" } });
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("content-range"), "bytes 1-3/6");
  assert.equal(await range.text(), "nsi");
});
