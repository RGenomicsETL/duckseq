// Shared setup for the browser tests: a local static server and headless Chromium.
import { chromium } from "playwright-core";
import { serve } from "../scripts/serve.mjs";

export async function openBrowser() {
  const server = await serve(new URL("..", import.meta.url).pathname, 0);
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const requests = [];
  const uploads = [];
  const newPage = async (path) => {
    const page = await browser.newPage();
    page.on("request", (r) => {
      requests.push(r.url());
      if (!["GET", "HEAD"].includes(r.method())) uploads.push({ method: r.method(), url: r.url() });
    });
    await page.goto(`${base}${path}`);
    return page;
  };
  const close = async () => {
    await browser.close();
    server.close();
  };
  return { base, newPage, requests, uploads, close };
}
