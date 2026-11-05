// The #1787 walk on a scratch root: a folder's Connectors page has the Messaging slot. With a
// Slack connector (a stand-in that lists three channels) and an email one that cannot be
// reached, each says its read; Change… asks where agents reach you and says the connectors are
// added on the Mac; None skips it and Set Up brings it back.
//
//   node Web/test/walk/messaging1787.mjs <WEB_URL> <browser code> <folder path> <out dir>

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
const card = `[...document.querySelectorAll(".slot")].find((c) => c.getAttribute("aria-label").startsWith("Messaging:"))`;
const inCard = (name) => page.eval(`(() => { const b = [...${card}.querySelectorAll("button")]
  .find((el) => el.textContent.trim() === ${JSON.stringify(name)}); if (!b) return false; b.click(); return true; })()`);
const shot = async (name) => {
  await page.eval(`${card}.scrollIntoView({ block: "center" })`);
  await scrub();
  await page.shot(`${out}/${name}.png`);
};

const chrome = await launch({ profile: `/tmp/run-1787-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 1000 });

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(has("Overview"), 20_000);
await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent(${JSON.stringify("file://" + folderPath + "/")}) + "/m/1"`);
await page.waitFor(has("Set up · "), 20_000).catch(async (e) => {
  await page.shot(`${out}/web-failed.png`);
  say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 300)}`);
  throw e;
});
await page.waitFor(has("Slack and Email"), 20_000);
const text = await page.text(".connector-setup");
check(text.includes("Slack (slack): read 3 channels; events slack.message, slack.mention"), "Slack's read and its events");
check(text.includes("Email (gmail): It could not be reached."), "the email connector's failure");
await shot("web-read");

check(await inCard("Change…"), "Change… on Messaging");
await page.waitFor(has("Where do agents reach you?"), 5_000);
check(await page.eval(has("add them on the Mac")), "the connectors are added on the Mac");
await shot("web-change");

check(await inCard("None (skip)"), "None");
await page.waitFor(has("Its connectors stay"), 10_000);
await shot("web-none-skipped");
check(await inCard("Set Up"), "Set Up");
await page.waitFor(`!document.body.textContent.includes("Its connectors stay")`, 10_000);
check(true, "set up again");

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
