// The #1484 walk: an MCP Apps view on the page at the control plane's own domain, drawn through
// the sandbox proxy at the views name. Pairs by a browser code, opens the folder's first
// session, says Show, waits for the view, and checks that its frame is the views name's
// /sandbox.html; then opens /sandbox.html at the page's own name, which is refused. Fails on any
// error the page throws.
//
//   SPKI="<pin> <pin>" node Web/test/walk/views1484.mjs <page URL> <browser code> <folder name> <out dir>
//
// SPKI is the base64 SHA-256 of each certificate's key (the page's name and the views name), for
// a test CA such as Pebble's. Expects a session whose agent called a server's tool with a view.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [pageURL, code, name, out] = process.argv.slice(2);
const views = new URL(pageURL);
views.hostname = views.hostname.replace(/^[^.]+/, "views");
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const spki = (process.env.SPKI ?? "").trim().split(/\s+/).filter(Boolean).join(",");
const chrome = await launch({ profile: `/tmp/1484-views-chrome-${process.pid}`,
  args: spki ? [`--ignore-certificate-errors-spki-list=${spki}`] : [] });

try {
  const page = await chrome.page(pageURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelector(".sidebar .row.session")`, 20_000);
  await page.eval(`document.querySelector(".sidebar .row.session").click()`);
  await page.waitFor(`document.querySelector(".app-view .view-ask, .view-layer iframe, .app-view .view-failure")`, 20_000);
  if (await page.eval(`!!document.querySelector(".app-view .view-ask")`)) {
    await page.shot(`${out}/web-1-show-ask.png`);
    await page.press("Show");
  }
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  await sleep(3000);
  const src = await page.eval(`document.querySelector(".view-layer iframe").src`);
  check(src.startsWith(`${views.origin}/sandbox.html?csp=`) && src.includes(`&host=${encodeURIComponent(new URL(pageURL).origin)}`),
    `the view's frame is the views name's proxy: ${src}`);
  const { frameTree } = await page.raw("Page.getFrameTree");
  const frames = [];
  const walk = (node) => { frames.push(node.frame.url); for (const child of node.childFrames ?? []) walk(child); };
  walk(frameTree);
  check(frames.some((url) => url.startsWith(`${views.origin}/sandbox.html`)), `frames: ${js(frames)}`);
  const failure = await page.eval(`document.querySelector(".app-view .view-failure")?.textContent ?? ""`);
  check(failure === "", `no failure in the view's place: ${js(failure)}`);
  await page.eval(`document.querySelector(".view-slot")?.scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/web-2-view.png`);
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);

  // The proxy is refused at the page's own name.
  const refused = await chrome.page(`${new URL(pageURL).origin}/sandbox.html`, { width: 800, height: 400 });
  const body = await refused.eval("document.body.innerText");
  check(body.trim() === "not here", `/sandbox.html at the page's name: ${js(body.trim())}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
