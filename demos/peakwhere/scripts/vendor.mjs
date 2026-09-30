// Copy the pinned npm packages into vendor/ as files a static server can serve.
// No network: everything comes from node_modules. Run after `npm ci`.
import { build } from "esbuild";
import { copyFile, mkdir } from "node:fs/promises";

const dist = "node_modules/@duckdb/duckdb-wasm/dist";

// duckdb-wasm's browser entry imports apache-arrow, so bundle it into one ES module.
for (const [entry, outfile] of [
  [`${dist}/duckdb-browser.mjs`, "vendor/duckdb.js"],
  ["node_modules/@observablehq/plot/src/index.js", "vendor/plot.js"],
]) {
  await build({
    entryPoints: [entry],
    outfile,
    bundle: true,
    format: "esm",
    minify: true,
    legalComments: "eof",
    logLevel: "warning",
  });
}

// The MVP and exception-handling bundles; duckdb-wasm picks one at runtime.
await mkdir("vendor/duckdb", { recursive: true });
for (const file of [
  "duckdb-mvp.wasm",
  "duckdb-browser-mvp.worker.js",
  "duckdb-eh.wasm",
  "duckdb-browser-eh.worker.js",
]) {
  await copyFile(`${dist}/${file}`, `vendor/duckdb/${file}`);
}
console.log("vendor/: duckdb-wasm and plot staged");

// The DuckHTS loader, until the `duckhts` npm package ships it (src/duckhts-loader.js).
await copyFile("src/duckhts-loader.js", "vendor/duckhts-loader.js");
