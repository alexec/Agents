// The #1461 walk: the page at the public control plane's own domain, with a public certificate
// (no pin). Pairs by a browser code, opens the session titled TITLE in PROJECT, checks that its MCP Apps
// view is drawn from the views name, and runs a turn in that session.
// Fails on any error the page throws.
//
//   node Web/test/walk/public1461.mjs <page URL> <browser code> <folder> <view session title> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [pageURL, code, folder, title, out] = process.argv.slice(2);
const views = new URL(pageURL);
views.hostname = views.hostname.replace(/^[^.]+/, "views");
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1461-public-chrome-${process.pid}` });

try {
  const page = await chrome.page(pageURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.shot(`${out}/web-1-pairing.png`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    for (const b of document.querySelectorAll(".sidebar .row.folder .disclosure"))
      if (b.getAttribute("aria-label").endsWith(${js(folder)}) && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  const session = `[...document.querySelectorAll(".sidebar .row.session")].find((r) => r.textContent.includes(${js(title)}))`;
  await page.waitFor(session, 20_000);
  await page.shot(`${out}/web-2-paired.png`);
  await page.eval(`${session}.click()`);
  await page.waitFor(`document.querySelector(".app-view .view-ask, .view-layer iframe, .app-view .view-failure")`, 20_000);
  if (await page.eval(`!!document.querySelector(".app-view .view-ask")`)) {
    await page.shot(`${out}/web-3-show-ask.png`);
    await page.press("Show");
  }
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  await sleep(3000);
  const src = await page.eval(`document.querySelector(".view-layer iframe").src`);
  check(src.startsWith(`${views.origin}/sandbox.html?csp=`), `the view's frame is the views name's proxy: ${src.split("?")[0]}`);
  const failure = await page.eval(`document.querySelector(".app-view .view-failure")?.textContent ?? ""`);
  check(failure === "", `no failure in the view's place: ${js(failure)}`);
  await page.eval(`document.querySelector(".view-slot")?.scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/web-4-view.png`);

  // A turn in the session from the browser.
  await page.focus("textarea");
  await page.type("Reply with exactly the one word: browser");
  await page.key("Enter");
  const answered = await page.waitFor(`[...document.querySelectorAll("main p, .transcript p")].some((p) => p.textContent.trim().toLowerCase() === "browser")`, 90_000)
    .then(() => true, () => false);
  await page.shot(`${out}/web-5-turn.png`);
  check(answered, "the turn answered: browser");
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
