// Static checks for the built Pages site.
// Usage: node scripts/check-site.mjs [site-dir]   (default: _site)
// Verifies routes, internal links and fragments, same-origin assets, basic accessibility
// structure, and required landing-page evidence labels and comparator caveats.
// Also runs peakwhere's own dataset checker when the app is present.
import { existsSync, readdirSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const site = resolve(process.argv[2] ?? "_site");
const errors = [];
const fail = (msg) => errors.push(msg);

const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const p = join(dir, name);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
const files = walk(site);
const rel = (p) => relative(site, p).split(sep).join("/");

// The peakwhere app is a separate program with its own checks; audit only our pages.
const ours = (p) => {
  const r = rel(p);
  return r === "index.html" || r.endsWith("/index.html") && !r.startsWith("peakwhere/") ||
    r === "peakwhere/performance/index.html";
};
const pages = files.filter((p) => p.endsWith(".html") && ours(p));

for (const route of ["index.html", "aie/index.html", "ldzip/index.html", "ldzip/review/index.html", "ldzip/native/index.html", "peakwhere/performance/index.html",
  "assets/site.css", "assets/favicon.svg", "LICENSE"]) {
  if (!existsSync(join(site, route))) fail(`missing ${route}`);
}
if (!process.env.SKIP_PEAKWHERE_APP) {
  if (!existsSync(join(site, "peakwhere/index.html"))) fail("missing peakwhere/index.html (the app)");
  if (!existsSync(join(site, "peakwhere/LICENSE"))) fail("missing peakwhere/LICENSE (MIT notice)");
}

// ---- HTML helpers (the pages are generated, so regex parsing is enough) ----
const attrs = (tag) => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*"([^"]*)"/g)].map((m) => [m[1].toLowerCase(), m[2]]));
const idsOf = (html) => new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
const decode = (s) => s.replace(/&amp;/g, "&");
const cache = new Map();
const read = async (p) => cache.get(p) ?? (cache.set(p, await readFile(p, "utf8")), cache.get(p));

function resolveInternal(fromFile, href) {
  const [pathPart, frag = ""] = decode(href).split("#");
  const clean = pathPart.split("?")[0];
  let target = clean === "" ? fromFile : resolve(dirname(fromFile), clean);
  if (clean.endsWith("/") || (existsSync(target) && statSync(target).isDirectory())) target = join(target, "index.html");
  return { target, frag };
}

const textOf = (html) => html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, "").replace(/<[^>]+>/g, " ")
  .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&rsquo;|&lsquo;/g, "'").replace(/&times;/g, "×").replace(/\s+/g, " ");

for (const page of pages) {
  const name = rel(page);
  const html = await read(page);
  if (!/<html[^>]*\slang="/.test(html)) fail(`${name}: <html> has no lang`);
  if (!/<title>[^<]+<\/title>/.test(html)) fail(`${name}: missing <title>`);
  if (!/name="viewport"/.test(html)) fail(`${name}: missing viewport meta`);
  if (!/class="skip"/.test(html)) fail(`${name}: missing skip link`);
  const h1 = (html.match(/<h1[\s>]/g) ?? []).length;
  if (h1 !== 1) fail(`${name}: expected one <h1>, found ${h1}`);
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (dup.length) fail(`${name}: duplicate ids ${[...new Set(dup)].join(", ")}`);
  for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!("alt" in attrs(m[0]))) fail(`${name}: <img> without alt`);
  if (/<script\b/i.test(html) && /<script[^>]*\ssrc="https?:/i.test(html)) fail(`${name}: external script`);

  // Same-origin assets: no external stylesheets, scripts, images, fonts or frames.
  for (const m of html.matchAll(/<(link|script|img|iframe|source|video|audio)\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    const ref = a.src ?? a.href ?? "";
    if (/^(https?:)?\/\//.test(ref)) fail(`${name}: external <${m[1]}> ${ref}`);
    if (ref.startsWith("/") && !ref.startsWith("//")) fail(`${name}: root-absolute <${m[1]}> ${ref} breaks /duckseq/ hosting`);
  }
  for (const m of html.matchAll(/<a\b[^>]*>/gi)) {
    const href = attrs(m[0]).href;
    if (href === undefined) continue;
    if (/^(https?:|mailto:)/.test(href)) {
      if (/^https?:\/\/(www\.)?github\.com\/RGenomicsETL\/duckseq\/(blob|tree)\/main\/(?!demos\/|README|LICENSE|AGENTS)/.test(href)) fail(`${name}: unexpected repo path ${href}`);
      if (/^https?:\/\/github\.com\/RGenomicsETL\/duckseq\/(blob|tree)\/main\//.test(href)) {
        const path = href.replace(/^.*\/(blob|tree)\/main\//, "").split("#")[0];
        if (!existsSync(join(repo, path))) fail(`${name}: GitHub link to a path not in the repository: ${path}`);
      }
      continue;
    }
    if (href.startsWith("/")) { fail(`${name}: root-absolute link ${href}`); continue; }
    const { target, frag } = resolveInternal(page, href);
    if (process.env.SKIP_PEAKWHERE_APP && target === join(site, "peakwhere/index.html")) continue;
    if (!existsSync(target)) { fail(`${name}: broken link ${href}`); continue; }
    if (frag && target.endsWith(".html")) {
      const targetIds = idsOf(await read(target));
      if (!targetIds.has(decodeURIComponent(frag))) fail(`${name}: no #${frag} in ${rel(target)}`);
    }
  }
  for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
    const href = attrs(m[0]).href;
    if (href && !/^https?:/.test(href) && !existsSync(resolveInternal(page, href).target)) fail(`${name}: broken <link> ${href}`);
  }
  // Table headers: every table needs header cells.
  for (const m of html.matchAll(/<table\b[\s\S]*?<\/table>/g)) if (!/<th[\s>]/.test(m[0])) fail(`${name}: table without header cells`);
}

// ---- CSS: no remote fonts, imports or images ----
for (const css of files.filter((p) => p.endsWith(".css") && rel(p).startsWith("assets/"))) {
  const text = await read(css);
  if (/@import|url\(\s*["']?(https?:)?\/\//.test(text)) fail(`${rel(css)}: remote @import or url()`);
  if (!/prefers-reduced-motion/.test(text)) fail(`${rel(css)}: no prefers-reduced-motion rule`);
  if (!/:focus-visible/.test(text)) fail(`${rel(css)}: no :focus-visible rule`);
}

// ---- Content: required headline text and explicit comparison limits ----
const landing = existsSync(join(site, "index.html")) ? textOf(await read(join(site, "index.html"))) : "";
const mustSay = ["7,220", "0.401 s", "0.370 s", "2.776 s", "335.3 MiB", "1,198.4 MiB", "189 ms", "107 ms",
  "20 to 35 times", "7 mutation checks", "6 mutation checks", "1×/2×/4×", "no performance benchmark", "not an equal-output speedup",
  "timed out", "The pair-speed comparison needs a fair rerun", "Measured, comparator gaps"];
for (const s of mustSay) if (!landing.toLowerCase().includes(s.toLowerCase())) fail(`index.html: expected text "${s}"`);
for (const banned of [/faster than (everything|all)/i, /universal(ly)?\b/i, /outperforms? (LDZip|Gravlax)/i, /AIE[^.]{0,60}\bbenchmark(ed)? (shows|results)/i]) {
  if (banned.test(landing)) fail(`index.html: overclaiming phrase ${banned}`);
}
// Demo routes advertised on the landing page and in every report's navigation.
for (const route of ["peakwhere/", "peakwhere/performance/", "aie/", "ldzip/", "ldzip/review/"]) {
  for (const p of pages) if (!(await read(p)).includes(`href="${rel(p).split("/").slice(0, -1).map(() => "../").join("")}${route}"`)) fail(`${rel(p)}: no link to ${route}`);
}

// ---- peakwhere's own dataset check ----
const appDir = join(site, "peakwhere");
if (existsSync(join(appDir, "vendor"))) {
  const r = spawnSync(process.execPath, ["scripts/check-site.mjs", appDir], { cwd: join(repo, "demos/peakwhere"), encoding: "utf8" });
  if (r.status !== 0) fail(`peakwhere dataset check failed:\n${r.stderr || r.stdout}`);
  else console.log(r.stdout.trim());
}

if (errors.length) {
  console.error(`site check failed (${errors.length}):\n- ${errors.join("\n- ")}`);
  process.exit(1);
}
console.log(`site check passed: ${pages.length} pages audited in ${site}`);
