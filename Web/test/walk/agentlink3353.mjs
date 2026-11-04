// The #3353 walk: a chat whose message links to other sessions with agents://agent/<id>, as the
// daily summary writes one per line. A click on a link selects that session. Needs a scratch root
// with a session titled "Daily summary" whose message links to one titled "Fix the login bug".
//
//   node Web/test/walk/agentlink3353.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-agentlink-chrome-${process.pid}` });
// The Overview's "Waiting for you" names each seeded session.
const sessionRow = (title) => `[...document.querySelectorAll("a, button")].find((e) => e.textContent.trim() === ${JSON.stringify(title)})`;
try {
  const page = await chrome.page(webURL, { width: 1300, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(sessionRow("Daily summary"), 30_000);
  await page.eval(`${sessionRow("Daily summary")}.click()`);
  const link = `[...document.querySelectorAll(".chat button.link")].find((b) => b.textContent === "Fix the login bug")`;
  await page.waitFor(link, 20_000);
  await new Promise((done) => setTimeout(done, 800));
  console.log(`summary: ${await page.eval(`location.hash`)}`);
  await page.shot(`${out}/web-summary.png`);

  const before = await page.eval(`location.hash`);
  await page.eval(`${link}.click()`);
  await page.waitFor(`location.hash !== ${JSON.stringify(before)}`, 20_000);
  await page.waitFor(`document.querySelector(".chat .column-head h1")?.textContent.includes("Fix the login bug")`, 20_000);
  await new Promise((done) => setTimeout(done, 800));
  console.log(`opened: ${await page.eval(`location.hash`)}`);
  console.log(`title: ${await page.text(".chat .column-head h1")}`);
  await page.shot(`${out}/web-opened.png`);
} finally {
  await chrome.close();
}
