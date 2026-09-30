// Immutable pre-port receipts, not an expectation generated from the measured SQL.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { CATEGORIES } from "../src/annotate.js";

const receipt = (name) => JSON.parse(execFileSync("git", ["show", `71c4674:benchmarks/head-to-head-${name}.json`], { encoding: "utf8" }));
const ours = receipt("ours")[0].counts;
const csv = receipt("upstream").find((r) => r.csv).csv;
const [header, ...lines] = csv.trim().split("\n").filter((l) => !l.startsWith("#"));
const columns = header.split(",");
const upstream = Object.fromEntries(lines.filter((l) => !l.startsWith("Genome,")).map((line) => {
  const fields = line.split(",");
  return [fields[0].split("_")[1], Object.fromEntries(CATEGORIES.map((c) => [c, Number(fields[columns.indexOf(c)])]))];
}));
assert.deepEqual(ours, upstream, "committed upstream CSV and duckpeakwhere receipts agree");

export function assertW2(counts) {
  assert.deepEqual(counts, upstream, "W2 centre counts equal upstream peakwhere f40a673");
  assert.deepEqual(counts, ours, "W2 centre counts equal pre-port duckpeakwhere 71c4674");
}
