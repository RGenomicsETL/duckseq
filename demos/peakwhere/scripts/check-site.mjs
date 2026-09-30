// Fail the Pages build if a dataset file the page offers is missing from the site.
// Usage: node scripts/check-site.mjs <site-dir>
// Reads the relative paths in src/app.js's DATASETS table; thymusFull's paths are the
// thymus peak files moved to vendor/peek-examples/ without ".chr19", as app.js derives them.
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const site = process.argv[2];
if (!site) throw new Error("usage: node scripts/check-site.mjs <site-dir>");
const source = await readFile("src/app.js", "utf8");
const listed = [...source.matchAll(/"((?:examples|test\/fixtures)\/[^"]+)"/g)].map((m) => m[1]);
const derived = listed.filter((p) => p.startsWith("examples/") && p.endsWith(".narrowPeak.gz"))
  .map((p) => p.replace("examples/", "vendor/peek-examples/").replace(".chr19", ""));
const missing = [...listed, ...derived].filter((p) => !existsSync(join(site, p)));
if (listed.length === 0) throw new Error("no dataset paths found in src/app.js");
if (missing.length) throw new Error(`missing from ${site}:\n  ${missing.join("\n  ")}`);
console.log(`${listed.length + derived.length} dataset files present in ${site}`);
