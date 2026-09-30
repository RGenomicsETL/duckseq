// One session per connection. Analyses, console queries and clears run serially.
import { annotate, clearAnnotation } from "./annotate.js";
import { peek, clearPeek } from "./peek.js";
import { createPeakStore } from "./peaks.js";

// Conservative: ambiguous scripts are treated as writes. The three cgranges probes
// are read-only; every other cgranges call may change an index.
function changesState(sql) {
  // Leading comments don't change what runs; the console's examples start with one.
  const statement = sql.replace(/^(?:\s|--[^\n]*|\/\*[\s\S]*?\*\/)*/, "").replace(/;\s*$/, "").trim();
  return !/^(?:SELECT|WITH|FROM|SHOW|DESCRIBE|SUMMARIZE|EXPLAIN)\b/i.test(statement) ||
    statement.includes(";") ||
    /\b(?:INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|COPY|CALL|ATTACH|DETACH|TRUNCATE|MERGE|SET|RESET|PRAGMA)\b/i.test(statement) ||
    /\bEXPLAIN\s+ANALYZE\b/i.test(statement) ||
    /\bduckhts_cgranges_(?!overlaps_list\b|count_overlaps\b|has_overlap\b)[a-z_]+\s*\(/i.test(statement);
}

export function createSession(conn) {
  let recording = null, lastStatements = [];
  const analysisConn = { query(sql) {
    recording?.push(sql);
    return conn.query(sql);
  } };
  const cache = {}, peaks = createPeakStore(analysisConn);
  let pending = Promise.resolve(), invalidated = false, live = {};
  const serial = (operation) => {
    const result = pending.then(operation);
    pending = result.catch(() => {});
    return result;
  };
  async function clear() {
    live = {};
    await clearAnnotation(analysisConn, cache);
    await peaks.clear();
    await clearPeek(analysisConn);
    invalidated = false;
  }
  return {
    run(view, request, observer = {}) {
      return serial(async () => {
        lastStatements = [];
        recording = lastStatements;
        try {
          if (invalidated) await clear();
          if (live.view === "peek") await clearPeek(analysisConn);
          live = {};
          const files = await peaks.sync(request.peaks);
          const result = view === "peek"
            ? await peek(analysisConn, request, { files, keepTables: true })
            : await annotate(analysisConn, request, { ...observer, cache, files });
          live = { ...request, view, files, settings: result.meta?.settings,
            format: result.meta?.format, partitionIndex: cache.partitionIndex };
          return result;
        } finally {
          recording = null;
        }
      });
    },
    query(sql) {
      return serial(() => {
        // Leave tables available for exploration; rebuild only after possible writes.
        invalidated ||= changesState(sql);
        return conn.query(sql);
      });
    },
    context: () => live,
    executedStatements: () => [...lastStatements],
    clear: () => serial(clear),
  };
}
