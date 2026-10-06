// The #189 walk: a pinned ui:// view on the web page. Pairs, unfolds the project, opens the
// pinned test view, and waits for it to be drawn full page through the sandbox proxy, fed by its
// pin's call. Fails on any error the page throws.
//
//   node Web/test/walk/pins189.mjs <WEB_URL> <browser code> <project name> <out dir>
//
// Expects the project to have the test view pinned (`pins/pin` with `view`), on a host started
// with AGENTS_TEST_VIEWS=1.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/189-pins-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.project .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 10_000);
  const titles = await page.eval(`[...document.querySelectorAll(".sidebar .row.pin .title")].map((t) => t.textContent)`);
  check(js(titles) === js(["Test view"]), `the view pin under the project: ${js(titles)}`);
  await page.eval(`document.querySelector(".sidebar .row.pin .pick").click()`);
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  await sleep(2500);
  check((await page.eval("location.hash")).includes("ui"), `the route names the view: ${await page.eval("location.hash")}`);
  await page.shot(`${out}/web-189-pinned-view.png`);
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
