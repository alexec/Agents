// The #191 walk: a person's own MCP server's view on the web page. Pairs, opens the project's
// first session, waits for the server's view to ask Show, says Show, waits for it to be drawn
// through the sandbox proxy, then opens the project's pinned view of the same server. Fails on
// any error the page throws.
//
//   node Web/test/walk/views191.mjs <WEB_URL> <browser code> <project name> <out dir>
//
// Expects a session whose agent called the server's tool with a view, the view's Show answer
// forgotten (`mcp/forgetViews`), and the view pinned in the project.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/191-views-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  const unfold = () => page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.project .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 1`, 20_000);
  await unfold();
  await page.waitFor(`document.querySelector(".sidebar .row.session")`, 20_000);
  await page.eval(`document.querySelector(".sidebar .row.session").click()`);
  await page.waitFor(`document.querySelector(".app-view .view-ask")`, 20_000);
  const asked = await page.text(".app-view .view-ask");
  check(asked.includes("wants to show a view here"), `the view asks first: ${js(asked.slice(0, 80))}`);
  const caption = await page.text(".app-view .view-caption");
  check(caption.includes("basic-vanillajs"), `the caption names the server: ${js(caption.slice(0, 60))}`);
  await page.shot(`${out}/web-191-1-show-ask.png`);
  await page.press("Show");
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  await sleep(3000);
  await page.shot(`${out}/web-191-2-inline.png`);

  await unfold();
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 10_000);
  await page.eval(`document.querySelector(".sidebar .row.pin .pick").click()`);
  await page.waitFor(`document.querySelector(".pinned-page .view-layer iframe")`, 15_000);
  await sleep(3000);
  await page.shot(`${out}/web-191-3-pinned.png`);
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
