// The #3304 walk on a scratch root: Connectors ▸ Connections has the Atlassian row; a folder's
// Tasks slot has Connect Jira…; the dialog has Atlassian Cloud and API token, says what to do
// when the machine has no Atlassian app, and ends on the site's newest issue. The site is a fake
// Jira on loopback (siteURL), with scratch data only.
//
//   node Web/test/walk/jira3304.mjs <WEB_URL> <browser code> <folder path> <fake site URL> <out dir>

import { hostname } from "node:os";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, siteURL, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
const fill = (selector, value) => page.eval(`(() => { const el = document.querySelector(${JSON.stringify(selector)});
  el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`);

const chrome = await launch({ profile: `/tmp/jira3304-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });
await page.onNewDocument("window.confirm = () => true;");

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(has("Overview"), 20_000);
await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent(${JSON.stringify("file://" + folderPath + "/")}) + "/m/1"`);
await page.waitFor(has("Set up · "), 20_000);
await page.waitFor(has("Connect Jira…"), 10_000);
check(true, "the Tasks slot has Connect Jira…");
await scrub();
await page.shot(`${out}/web-tasks-slot.png`);

await page.press("Connect Jira…");
await page.waitFor(has("One Atlassian sign-in for Jira and Confluence"), 5_000);
await scrub();
await page.shot(`${out}/web-sign-in.png`);
await page.press("Continue on atlassian.com");
await page.waitFor(has("no Agents app on Atlassian"), 10_000);
check(true, "with no Atlassian app, it says to use an API token");
await scrub();
await page.shot(`${out}/web-no-app.png`);

await page.press("API token");
await page.waitFor(`document.querySelector("#connect-token")`, 5_000);
await fill("#connect-token input[type=text]", "walk.atlassian.net");
await fill("#connect-token input[type=email]", "sam@example.com");
await fill("#connect-token input[type=password]", "scratch-token");
await scrub();
await page.shot(`${out}/web-api-token.png`);
await fill("#connect-token input[type=text]", siteURL);
await page.eval(`document.querySelector("button[form=connect-token]").click()`);
await page.waitFor(has("Newest issue: WALK-7"), 15_000);
check(true, "connected, with the newest issue");
await scrub();
await page.shot(`${out}/web-connected.png`);
await page.press("Done");
// Connectors ▸ Connections: the row says Atlassian, and how it signs in.
await page.eval(`location.hash = "#/machines/mcp"`);
await page.waitFor(has("Atlassian · Sam Walker"), 10_000).then(async () => {
  check(await page.eval(has("API token")), "the row says it is an API token");
  await scrub();
  await page.shot(`${out}/web-connections.png`);
}, () => check(false, "Connectors ▸ Connections"));

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
