// Reports ▸ Lineage (#3087): on a run-app root with a milestone, issues, sessions and PRs linked by
// lineage/link, open the page with nothing started, start from the milestone's address, click a session's
// box to start from it, go Back, then a session's Lineage tab and its Explore. Screenshots into <out dir>.
//
//   node Web/test/walk/lineage3087.mjs <WEB_URL> <browser code> <out dir> <milestone address> <session title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, milestone, session] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/lin3087-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const start = () => page.eval(`document.querySelector(".lineage-start strong")?.textContent`);
const graph = () => page.waitFor(`[...document.querySelectorAll(".lineage-graph .lineage-box .detail")].some((d) => d.textContent.includes("·"))`, 30_000);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/reports/lineage"`);
  await page.waitFor(`document.querySelector(".lineage-page .hint")`, 30_000);
  ok("nothing started says how to start", (await page.eval(`document.querySelector(".lineage-page .hint").textContent`)).startsWith("Start from a session"));
  await sleep(400);
  await page.shot(`${out}/web-empty.png`);

  await page.focus(`.lineage-bar input`);
  await page.type(milestone);
  // cdp.mjs's key types no text, so Return would not submit: the form is sent as Return sends it.
  await page.eval(`document.querySelector(".lineage-bar").requestSubmit()`);
  await graph().catch(async (e) => { await page.shot(`${out}/debug.png`); throw e; });
  ok(`starts from the milestone: ${await start()}`, (await start()).includes("milestone"));
  await sleep(400);
  await page.shot(`${out}/web-milestone.png`);

  await page.eval(`[...document.querySelectorAll(".lineage-box[role=button]")].find((b) => b.querySelector(".name")?.textContent === ${JSON.stringify(session)})?.dispatchEvent(new MouseEvent("click", { bubbles: true }))`);
  await page.waitFor(`document.querySelector(".lineage-start strong")?.textContent === ${JSON.stringify(session)}`, 30_000);
  await graph();
  ok(`a click starts from the session: ${await start()}`, (await start()) === session);
  await sleep(400);
  await page.shot(`${out}/web-recentred.png`);

  await page.press("Back");
  await page.waitFor(`document.querySelector(".lineage-start strong")?.textContent.includes("milestone")`, 30_000);
  ok("Back goes to the milestone", true);

  await page.press("Forward");
  await page.waitFor(`document.querySelector(".lineage-start strong")?.textContent === ${JSON.stringify(session)}`, 30_000);
  await page.press("Show the chat");
  await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
  await page.press("Files");
  await page.waitFor(`document.querySelector("aside.files")`, 30_000);
  await page.eval(`[...document.querySelectorAll("aside.files [role=tab]")].find((t) => t.textContent === "Lineage")?.click()`);
  await graph();
  await sleep(400);
  await page.shot(`${out}/web-session-pane.png`);
  await page.press("Explore");
  await page.waitFor(`location.hash === "#/reports/lineage"`, 30_000);
  await graph();
  ok(`Explore opens the page on the session: ${await start()}`, (await start()) === session);
} finally {
  await chrome.close();
}
