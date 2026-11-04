// For Review's pull requests (#3330): on a run-app root whose folder is on the fixture GitHub
// (forge3330-github.py, AGENTS_TEST_GITHUB_URL), the group lists the open pull requests labelled
// needs-approval and not approved; Dismiss shows on hover, and pressed takes the row out.
// Screenshots into <out dir>.
//
//   node Web/test/walk/forreview3330.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-fr3330-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1100, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const rows = () => page.eval(`[...document.querySelectorAll(".smart.forReview .review-pull .name")].map((e) => e.textContent)`);
const count = () => page.eval(`document.querySelector(".smart.forReview summary .count")?.textContent ?? ""`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  // The sidebar is the Agents page's.
  await page.press("Agents");
  await page.waitFor(`document.querySelector(".smart.forReview .review-pull")`, 60_000);
  await sleep(400);
  ok(`For Review lists #31 and #32, not the approved #33: ${await rows()}`,
    JSON.stringify(await rows()) === JSON.stringify(["Checkout: a gift card field", "Cart: a quieter empty state"]));
  ok(`its heading counts them: ${await count()}`, (await count()) === "2");
  await page.shot(`${out}/web-for-review.png`);

  // The pointer over the first row: Dismiss in the time's place.
  const at = await page.eval(`(() => { const r = document.querySelector(".review-pull").getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  await page.raw("Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
  await sleep(300);
  ok("Dismiss shows on hover", await page.eval(`getComputedStyle(document.querySelector(".review-pull > .dismiss")).display !== "none"`));
  await page.shot(`${out}/web-hover-dismiss.png`);

  await page.press("Dismiss Checkout: a gift card field");
  await page.waitFor(`document.querySelectorAll(".smart.forReview .review-pull").length === 1`, 10_000);
  await page.raw("Input.dispatchMouseEvent", { type: "mouseMoved", x: 900, y: 600 });
  await sleep(1500);
  ok(`Dismissed, it is gone: ${await rows()}`, JSON.stringify(await rows()) === JSON.stringify(["Cart: a quieter empty state"]));
  ok(`the count says 1: ${await count()}`, (await count()) === "1");
  await page.shot(`${out}/web-dismissed.png`);
} finally {
  await chrome.close();
}
