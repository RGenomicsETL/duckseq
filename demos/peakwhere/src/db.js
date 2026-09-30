// Start duckdb-wasm from vendor/ and load DuckHTS into it. No request leaves the origin.
import * as duckdb from "../vendor/duckdb.js";
import { loadDuckhts } from "../vendor/duckhts-loader.js";

const vendor = new URL("../vendor/", import.meta.url);

/** @returns {Promise<{db: duckdb.AsyncDuckDB, conn: duckdb.AsyncDuckDBConnection, platform: string, version: string}>} */
export async function openDatabase() {
  const dev = new URLSearchParams(location.search).get("duckhts") === "dev";
  const bundle = await duckdb.selectBundle({
    mvp: {
      mainModule: new URL("duckdb/duckdb-mvp.wasm", vendor).href,
      mainWorker: new URL("duckdb/duckdb-browser-mvp.worker.js", vendor).href,
    },
    eh: {
      mainModule: new URL("duckdb/duckdb-eh.wasm", vendor).href,
      mainWorker: new URL("duckdb/duckdb-browser-eh.worker.js", vendor).href,
    },
  });
  const db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), new Worker(bundle.mainWorker));
  await db.instantiate(bundle.mainModule);
  // Only the explicit development switch admits the pinned unsigned build.
  await db.open({ allowUnsignedExtensions: dev });
  const conn = await db.connect();
  const { platform } = await loadDuckhts(conn, { baseUrl: new URL(dev ? "duckhts-dev/" : "duckhts/", vendor).href });
  const version = String((await conn.query("SELECT version() AS v")).toArray()[0].v);
  return { db, conn, platform, version };
}
