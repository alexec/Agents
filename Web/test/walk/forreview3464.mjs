// For Review's unread pull requests (#3464): on a run-app root whose folder is on the fixture GitHub
// (forge3330-github.py, AGENTS_TEST_GITHUB_URL), a pull request not yet opened has a bold title; a
// press on it opens its Work page and draws it read, here and, through the host, on every client.
// Screenshots into <out dir>.
//
//   node Web/test/walk/forreview3464.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-fr3464-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1100, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const weights = () => page.eval(`[...document.querySelectorAll(".smart.forReview .review-pull .name")]
  .map((e) => getComputedStyle(e).fontWeight)`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  for (let i = 0; i < 30 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await sleep(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits, then Approve");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
  }
  await page.press("Agents");
  await page.waitFor(`document.querySelectorAll(".smart.forReview .review-pull").length === 2`, 60_000);
  await sleep(400);
  ok(`both titles are bold before a press: ${await weights()}`, JSON.stringify(await weights()) === '["600","600"]');
  await page.shot(`${out}/web-unread.png`);

  // A press on the first row: its Work page opens in the app, and back in Agents its title is no longer bold.
  await page.eval(`document.querySelector(".review-pull > a.row").click()`);
  await page.waitFor(`location.hash.startsWith("#/work/pr/")`, 10_000);
  ok(`the Work page of the pull request: ${await page.eval("decodeURIComponent(location.hash)")}`,
    (await page.eval("decodeURIComponent(location.hash)")).startsWith("#/work/pr/github:"));
  await sleep(1500);
  await page.shot(`${out}/web-work-page.png`);
  await page.press("Agents");
  await page.waitFor(`document.querySelector(".review-pull") && !document.querySelector(".review-pull").classList.contains("unread")`, 10_000);
  await page.raw("Input.dispatchMouseEvent", { type: "mouseMoved", x: 900, y: 600 });
  await sleep(800);
  ok(`opened, the first is normal and the second still bold: ${await weights()}`,
    JSON.stringify(await weights()) === '["400","600"]');
  await page.shot(`${out}/web-opened.png`);
} finally {
  await chrome.close();
}
