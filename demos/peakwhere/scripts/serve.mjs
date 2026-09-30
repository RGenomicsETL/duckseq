// Static file server for local use and tests. Supports HTTP Range requests, which
// DuckHTS's browser HTTP reader uses to read BGZF files.
import { createServer } from "node:http";
import { open, stat } from "node:fs/promises";
import path from "node:path";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
};

export function serve(dir, port = 0) {
  const root = path.resolve(dir);
  const server = createServer(async (req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname);
    const file = path.join(root, pathname.endsWith("/") ? `${pathname}index.html` : pathname);
    if (!file.startsWith(root)) {
      res.writeHead(403).end();
      return;
    }
    let size;
    try {
      const info = await stat(file);
      if (!info.isFile()) throw new Error("not a file");
      size = info.size;
    } catch {
      res.writeHead(404).end();
      return;
    }
    const headers = {
      "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream",
      "Accept-Ranges": "bytes",
    };
    let start = 0;
    let end = size - 1;
    let status = 200;
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
    if (range) {
      if (range[1] === "") {
        start = Math.max(0, size - Number(range[2]));
      } else {
        start = Number(range[1]);
        if (range[2] !== "") end = Math.min(end, Number(range[2]));
      }
      if (start > end || start >= size) {
        res.writeHead(416, { "Content-Range": `bytes */${size}` }).end();
        return;
      }
      status = 206;
      headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
    }
    headers["Content-Length"] = end - start + 1;
    res.writeHead(status, headers);
    if (req.method === "HEAD" || size === 0) {
      res.end();
      return;
    }
    const handle = await open(file);
    handle.createReadStream({ start, end }).pipe(res);
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = await serve(path.resolve("."), Number(process.env.PORT ?? 8000));
  console.log(`http://127.0.0.1:${server.address().port}/`);
}
