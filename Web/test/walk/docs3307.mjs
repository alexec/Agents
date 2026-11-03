// The #3307 walk on a scratch root: a folder's Connectors page shows each docs connector's one
// real search through its map (the first doc found, or why not) under the Docs slot.
//
//   node Web/test/walk/docs3307.mjs <WEB_URL> <browser code> <folder path> <out png> <text to wait for>

import { hostname } from "node:os";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, out, expected] = process.argv.slice(2);
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;

const chrome = await launch({ profile: `/tmp/run-docs3307-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });
let failed = false;
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(has("Overview"), 20_000);
  await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent(${JSON.stringify("file://" + folderPath + "/")}) + "/m/1"`);
  await page.waitFor(has("Set up · "), 20_000);
  await page.waitFor(has(expected), 20_000);
  // The repo is public: this Mac's own name leaves the page before the shot.
  await page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
  console.log(`ok   ${expected}`);
} catch (e) {
  failed = true;
  console.log(`FAIL ${expected}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 400)}`);
}
await page.shot(out);
await chrome.close();
process.exit(failed ? 1 : 0);
