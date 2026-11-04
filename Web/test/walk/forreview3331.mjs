// For Review's suggestions of the daily checks (#3331): on a run-app root whose host has a scratch
// home (--env AGENTS_PERSONAL_HOME=…) holding ~/.agents/checks/suggestions.json, the group lists
// them after its pull requests, the urgent first; Start and Dismiss show on hover; Dismiss takes a
// row out, and Start opens the new session. Screenshots into <out dir>.
//
//   node Web/test/walk/forreview3331.mjs <WEB_URL> <browser code> <out dir> <dismiss title> <start title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, dismissTitle, startTitle] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-fr3331-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1100, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const rows = () => page.eval(`[...document.querySelectorAll(".smart.forReview .check-suggestion .name")].map((e) => e.textContent)`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.press("Agents");
  await page.waitFor(`document.querySelector(".smart.forReview .check-suggestion")`, 60_000);
  await sleep(400);
  const listed = await rows();
  ok(`For Review lists the suggestions, the urgent first: ${listed}`, listed.length >= 2 && listed[0] === "CI fails on main");
  ok("the urgent one has the attention mark", await page.eval(`!!document.querySelector(".check-suggestion .sidebar-mark.suggestion.urgent")`));
  await page.shot(`${out}/web-for-review.png`);

  // The pointer over the first row: Start and Dismiss in the time's place.
  const at = await page.eval(`(() => { const r = document.querySelector(".check-suggestion").getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  await page.raw("Input.dispatchMouseEvent", { type: "mouseMoved", x: at.x, y: at.y });
  await sleep(300);
  ok("Start and Dismiss show on hover", await page.eval(`getComputedStyle(document.querySelector(".check-suggestion > .actions")).display !== "none"`));
  const edges = await page.eval(`(() => {
    const row = document.querySelector(".check-suggestion");
    return { title: Math.round(row.querySelector(".name").getBoundingClientRect().right),
      line: Math.round(row.querySelector(".subtitle").getBoundingClientRect().right),
      buttons: Math.round(row.querySelector(".actions").getBoundingClientRect().left) }; })()`);
  ok(`the title and its line are cut before them, not covered: ${JSON.stringify(edges)}`,
    Math.max(edges.title, edges.line) <= edges.buttons + 1);
  await page.shot(`${out}/web-hover.png`);

  await page.press(`Dismiss ${dismissTitle}`);
  await page.waitFor(`![...document.querySelectorAll(".check-suggestion .name")].some((e) => e.textContent === ${JSON.stringify(dismissTitle)})`, 10_000);
  await page.raw("Input.dispatchMouseEvent", { type: "mouseMoved", x: 900, y: 600 });
  await sleep(1500);
  ok(`Dismissed, it is gone: ${await rows()}`, !(await rows()).includes(dismissTitle));
  await page.shot(`${out}/web-dismissed.png`);

  await page.press(`Start a session on ${startTitle}`);
  await page.waitFor(`location.hash.includes("/s/") || location.hash.includes("session")`, 30_000);
  await sleep(3000);
  ok(`Started, it is gone and its session is open: ${await rows()}`, !(await rows()).includes(startTitle));
  await page.shot(`${out}/web-started.png`);
} finally {
  await chrome.close();
}
