// The Summary row and page (#3721): on a run-app root whose host has a scratch home
// (--env AGENTS_PERSONAL_HOME=…) holding saved pages in ~/.agents/summaries, with the daily
// summary on, the sidebar has a Summary row under New Session with the newest page's title and
// a dot while it is unread; it opens the page, the newest page read, and the dot goes.
// Screenshots into <out dir>.
//
//   node Web/test/walk/summary3721.mjs <WEB_URL> <browser code> <out dir> <newest title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, newest] = process.argv.slice(2);
const chrome = await launch({ profile: process.env.WALK_PROFILE ?? `/tmp/sum3721-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1100, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };

try {
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".nav-item")`, 20_000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.press("Agents");
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  for (let i = 0; i < 30 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await sleep(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits, then Approve");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
  }
  try {
    await page.waitFor(`document.querySelector(".summary-row")`, 60_000);
  } catch (e) {
    console.log(page.console.slice(-30).join("\n"));
    throw e;
  }
  await sleep(500);
  const line = await page.eval(`document.querySelector(".summary-row .line")?.textContent`);
  ok(`the row names the newest page: ${line}`, line === newest);
  ok("the row has the unread dot", await page.eval(`!!document.querySelector(".summary-row.unread .dot")`));
  await page.shot(`${out}/web-row-unread.png`);

  await page.eval(`document.querySelector(".summary-row").click()`);
  await page.waitFor(`document.querySelector(".summary-page .summary-body h1")`, 15_000);
  await sleep(1500);
  const heading = await page.eval(`document.querySelector(".summary-page .summary-body h1")?.textContent`);
  ok(`the page shows the newest page: ${heading}`, heading === newest);
  ok("read, the row's dot goes", await page.eval(`!document.querySelector(".summary-row.unread")`));
  await page.shot(`${out}/web-page.png`);
} finally {
  await chrome.close();
}
