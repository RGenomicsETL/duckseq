// Load the DuckHTS extension into a duckdb-wasm connection from a URL the app serves.
//
// This is the interface the `duckhts` npm package is planned to export
// (https://github.com/RGenomicsETL/duckhts/issues/246). Until it is published, this
// copy lives here and scripts/vendor.mjs copies it to vendor/duckhts-loader.js.
//
// `baseUrl` holds one signed build per platform: `${baseUrl}/${platform}/duckhts.duckdb_extension.wasm`.
// DuckHTS uses the DuckDB C API v1, so one build serves every DuckDB >= v1.2.0 and < v2.

const WASM_PLATFORMS = new Set(["wasm_mvp", "wasm_eh", "wasm_threads"]);

// Contract from https://github.com/RGenomicsETL/duckhts/pull/248; replace with the npm export.
// Keep the URL alive until every query using it has completed (including after errors).
export function localFileUrl(file) {
  if (!(file instanceof Blob)) throw new TypeError("localFileUrl expects a File or Blob");
  const url = URL.createObjectURL(file);
  return { url, revoke: () => URL.revokeObjectURL(url) };
}

/** Probe the loaded build, not its version: signed releases may lag blob transport. */
export async function supportsLocalFiles(conn) {
  const source = localFileUrl(new Blob(["chr1\t0\t1\n"]));
  try {
    const rows = await conn.query(`SELECT count(*) AS n FROM read_bed('${source.url}', scan_mode := 'sequential')`);
    return Number(rows.toArray()[0].n) === 1;
  } catch (error) {
    if (/failed to open file/i.test(error.message)) return false;
    throw error;
  } finally {
    source.revoke();
  }
}

/**
 * @param {import("@duckdb/duckdb-wasm").AsyncDuckDBConnection} conn
 * @param {{baseUrl: string}} options
 * @returns {Promise<{platform: string}>}
 */
export async function loadDuckhts(conn, { baseUrl }) {
  const result = await conn.query("PRAGMA platform");
  const platform = String(result.getChildAt(0).get(0));
  if (!WASM_PLATFORMS.has(platform)) {
    throw new Error(
      `DuckHTS wasm builds exist for ${[...WASM_PLATFORMS].join(", ")}; this DuckDB reports "${platform}".`,
    );
  }
  const url = new URL(`${platform}/duckhts.duckdb_extension.wasm`, `${baseUrl.replace(/\/?$/, "/")}`);
  await conn.query(`LOAD '${url.href.replaceAll("'", "''")}'`);
  return { platform };
}
