// Work pages' Previous and Next (#3257): on a run-app root whose folder's repo is the fixture GitHub's
// example/shop (forge3130-github.py, AGENTS_TEST_GITHUB_URL), open Work ▸ Issues, filter by words and
// clear it, open the first row's page, go down the list with j and the Next button to its last row
// (Next off there), up with k, Back to the list (its filter kept), and open a pasted address (no
// Previous or Next). Screenshots into <out dir>.
//
//   node Web/test/walk/work3257.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/w3257-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const position = () => page.eval(`document.querySelector(".work-stepper")?.textContent ?? ""`);
const key = (k) => page.eval(`document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "${k}", bubbles: true }))`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 3`, 30_000);
  const entries = await page.eval("history.length");
  await page.shot(`${out}/web-list.png`);

  await page.eval(`document.querySelector(".work-row").click()`);
  await page.waitFor(`document.querySelector(".work-stepper") && document.querySelector(".work-page-head")`, 30_000);
  await sleep(500);
  ok(`the first row's page says 1 of 3: ${await position()}`, (await position()).includes("1 of 3"));
  ok("Previous is off on the first", await page.eval(`document.querySelector('[aria-label="Previous"]').disabled`));
  await page.shot(`${out}/web-first.png`);

  await key("j");
  await page.waitFor(`document.querySelector(".work-stepper")?.textContent.includes("2 of 3")`, 10_000);
  await sleep(500);
  ok("j goes to the next row", true);
  await page.shot(`${out}/web-middle.png`);

  await page.eval(`document.querySelector('[aria-label="Next"]').click()`);
  await page.waitFor(`document.querySelector(".work-stepper")?.textContent.includes("3 of 3")`, 10_000);
  await sleep(500);
  ok("Next is off on the last", await page.eval(`document.querySelector('[aria-label="Next"]').disabled`));
  await page.shot(`${out}/web-last.png`);

  await key("k");
  await page.waitFor(`document.querySelector(".work-stepper")?.textContent.includes("2 of 3")`, 10_000);
  ok("k goes to the row above", true);
  ok(`Previous and Next replace the place: ${await page.eval("history.length")} entries`, (await page.eval("history.length")) === entries + 1);

  await page.press("Back");
  await page.waitFor(`location.hash === "#/work/issue" && document.querySelectorAll(".work-row").length === 3`, 10_000);
  ok("Back goes to the list", true);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#17")`);
  await page.waitFor(`document.querySelector(".work-page-head")?.textContent.includes("coupon")`, 30_000);
  await sleep(500);
  ok("a pasted address has no Previous or Next", await page.eval(`!document.querySelector(".work-stepper")`));
  await page.shot(`${out}/web-no-list.png`);
} catch (e) {
  console.log(`FAIL ${e.message}`);
  await page.shot(`${out}/web-failed.png`).catch(() => {});
  process.exitCode = 1;
} finally {
  await chrome.close();
}
