// The #3248 walk on a scratch root: a folder's Connectors page has the Docs slot, with this
// folder's newest doc and its docs connectors; Change… asks where the docs live and says the
// connectors are added on the Mac; None skips it and Set Up brings it back.
//
//   node Web/test/walk/docs3248.mjs <WEB_URL> <browser code> <folder path> <out dir>

import { hostname } from "node:os";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;

const chrome = await launch({ profile: `/tmp/docs3248-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
// The folder's Connectors page, by its address: the console opens on Overview.
await page.waitFor(has("Overview"), 20_000);
await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent(${JSON.stringify("file://" + folderPath + "/")}) + "/m/1"`);
await page.waitFor(has("Set up · "), 20_000).catch(async (e) => {
  await page.shot(`${out}/web-failed.png`);
  say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 300)}`);
  throw e;
});
await page.waitFor(has("This folder"), 20_000);
const text = await page.text(".connector-setup");
check(/docs/i.test(text) && text.includes("This folder and Notion"), "the Docs slot and its connector");
check(text.includes("Connectors: notion"), "the docs connectors line");
await scrub();
await page.shot(`${out}/web-read.png`);

await page.press("Change…");
await page.waitFor(has("Where do your docs live?"), 5_000);
check(await page.eval(has("add them on the Mac")), "the connectors are added on the Mac");
await scrub();
await page.shot(`${out}/web-change.png`);

await page.press("None (skip)");
await page.waitFor(has("Agents won't look for docs"), 10_000);
check(true, "skipped");
await scrub();
await page.shot(`${out}/web-skipped.png`);
await page.press("Set Up");
await page.waitFor(`!document.body.textContent.includes("Agents won't look for docs")`, 10_000);
check(true, "set up again");

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
