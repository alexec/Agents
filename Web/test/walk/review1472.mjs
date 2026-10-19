// The #1472 walk: a change waiting for an OK, on its Review page on the web. Pairs, opens the waiting
// workflow from Needs You, checks the whole change is there with its numbers and folds, opens a fold,
// switches to Side by Side, and answers Approve from the bar at the foot.
//
//   node Web/test/walk/review1472.mjs <WEB_URL> <browser code> <workflow title> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, title, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1472-review-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.approval .name")].some((n) => n.textContent === ${js(title)})`, 20_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.approval")].find((b) => b.querySelector(".name").textContent === ${js(title)}).click()`);
  await page.waitFor(`document.querySelector(".review-page .file-diff .line")`, 10_000);
  await sleep(300);
  check((await page.eval("location.hash")).includes("/rv/workflow%3A"), `the route names the change: ${await page.eval("location.hash")}`);
  const numbers = await page.eval(`[...document.querySelectorAll(".review-page .file-diff .line .number")].map((n) => n.textContent).filter(Boolean).map(Number)`);
  check(Math.max(...numbers) >= 250, `line numbers reach the last change, near the end of the file: ${Math.max(...numbers)}`);
  const folds = await page.eval(`document.querySelectorAll(".review-page .file-diff .fold").length`);
  check(folds >= 2, `unchanged runs are folded: ${folds}`);
  check(await page.eval(`!!document.querySelector(".review-page .review-bar .prominent")`), "Approve is in the bar");
  await page.shot(`${out}/web-1-review.png`);

  await page.eval(`document.querySelector(".review-page .file-diff .fold").click()`);
  await sleep(200);
  check(await page.eval(`document.querySelectorAll(".review-page .file-diff .fold").length`) === folds - 1, "a fold opens in place");
  await page.press("Side by Side");
  await page.waitFor(`document.querySelector(".review-page .file-diff.split .pair")`, 5_000);
  await page.eval(`document.querySelector(".review-page .scroll").scrollTop = 1e6`);
  await sleep(200);
  check(await page.eval(`(() => { const b = document.querySelector(".review-bar").getBoundingClientRect(); return b.bottom <= innerHeight + 1 && b.top > 0; })()`),
    "the bar stays in view at the end of the change");
  await page.shot(`${out}/web-2-side-by-side-end.png`);

  await page.press("Approve");
  await page.waitFor(`!location.hash.includes("/rv/")`, 10_000);
  check(await page.eval(`![...document.querySelectorAll(".sidebar .row.approval .name")].some((n) => n.textContent === ${js(title)})`),
    "answered from the page, it leaves Needs You");
  await page.shot(`${out}/web-3-answered.png`);
  const errors = page.errors ?? [];
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
