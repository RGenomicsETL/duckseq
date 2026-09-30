// Check out upstream peakwhere at the pinned commit into bench/.cache/peakwhere-upstream.
// Its app runs as committed (vendor/ is checked in), so no build step is needed.
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

const REPO = "https://github.com/seandavi/peakwhere";
const COMMIT = "f40a673842815b9eef08c4d32243b29dac3e0646";
const dir = "bench/.cache/peakwhere-upstream";
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

if (!existsSync(dir)) git("clone", "--quiet", REPO, dir);
git("-C", dir, "fetch", "--quiet", "origin", COMMIT);
git("-C", dir, "checkout", "--quiet", "--detach", COMMIT);
const head = git("-C", dir, "rev-parse", "HEAD");
if (head !== COMMIT) throw new Error(`upstream at ${head}, expected ${COMMIT}`);
console.log(`peakwhere upstream: ${head}`);
