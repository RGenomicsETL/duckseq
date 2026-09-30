import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { openBrowser } from "./browser.js";

let browser, page;
before(async () => {
  browser = await openBrowser();
  page = await browser.newPage("/test/harness.html");
  await page.waitForFunction(() => !!window.runSession);
});
after(() => browser.close());

test("Where and Peek show exactly the queries executed, including a cached rerun", async () => {
  const got = await page.evaluate(async () => {
    await window.clearSession();
    const base = `${location.origin}/test/fixtures/`;
    const request = { annotation: `${base}fixture.gff3`, peaks: [{ url: `${base}peaks.bed`, label: "p" }] };
    window.takeQueries();
    const runs = [];
    for (const view of ["where", "where", "peek"]) {
      await window.runSession(view, request);
      const actual = window.takeQueries();
      const recorded = await window.executedStatements();
      const shown = document.querySelector(`#${view}-results .executed-sql pre`).textContent;
      runs.push({ actual, recorded, shown });
    }
    return runs;
  });
  for (const run of got) {
    assert.deepEqual(run.recorded, run.actual);
    assert.equal(run.shown, run.actual.join("\n;\n"));
  }
  assert.match(got[0].shown, /read_gff\(/);
  assert.doesNotMatch(got[1].shown, /read_gff\(|read_gtf\(|read_bed\(/);
  assert.match(got[2].shown, /peek_valid/);
});

test("Open in console loads the Where and Peek statements into the SQL input", async () => {
  const app = await browser.newPage("/");
  await app.waitForFunction(() => !document.querySelector("#run").disabled);
  await app.selectOption("#dataset", "fixture");
  for (const view of ["where", "peek"]) {
    await app.selectOption("#view", view);
    await app.click("#run");
    await app.waitForSelector('body[data-state="done"] #run:not([disabled])');
    const details = app.locator(`#${view}-results .executed-sql`);
    await details.locator("summary").click();
    const shown = await details.locator("pre").textContent();
    assert.ok(shown.length > 0);
    await details.getByRole("button", { name: "Open in console" }).click();
    assert.equal(await app.inputValue("#sql-input"), shown);
    assert.equal(await app.locator("#sql-console").evaluate((el) => el.open), true);
  }
  await app.close();
});
