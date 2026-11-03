// Jira in the Work pages (#3260): on a run-app root whose folder names the fixture Jira's project
// SHOP (forge3260-jira.py), open Work ▸ Issues and see the Jira issues with their statuses and the
// tracker filter; open SHOP-12's page (its description as Markdown, its comments, Open on Jira,
// Start Agent and its status menu in place of Close); open the status menu and move it; add a
// label; write a comment. Screenshots into <out dir>.
//
//   node Web/test/walk/work3260.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-jira3260-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const click = (text, scope = "button") => page.eval(`[...document.querySelectorAll(${JSON.stringify(scope)})].find((b) => b.textContent.trim() === ${JSON.stringify(text)}).click()`);
const said = () => page.eval(`document.querySelector(".work-actions [role=status]")?.textContent ?? ""`);
const pills = () => page.eval(`[...document.querySelectorAll(".work-row .work-state")].map((p) => p.textContent)`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 3`, 30_000);
  ok(`the Jira issues are listed with their statuses: ${await pills()}`,
    (await pills()).join(",") === "In Progress,In Review,To Do");
  ok("Jira is a tracker to filter by", await page.eval(`[...document.querySelectorAll(".work-filters option")].some((o) => o.textContent.includes("Jira"))`));
  await sleep(400);
  await page.shot(`${out}/web-issues.png`);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("jira:SHOP-12")`);
  await page.waitFor(`document.querySelector(".work-actions") && document.querySelector(".work-comment-box")`, 30_000);
  ok("the page has Start Agent, the status menu and Labels, and no Close",
    await page.eval(`(() => { const t = [...document.querySelectorAll(".work-actions button")].map((b) => b.textContent);
      return ["Start Agent", "In Progress ▾", "Labels ▾"].every((x) => t.includes(x)) && !t.includes("Close"); })()`));
  ok("the description is Markdown, drawn", await page.eval(`[...document.querySelectorAll("h3")].some((h) => h.textContent === "Steps")`));
  ok("Open on Jira", await page.eval(`[...document.querySelectorAll("a")].some((a) => a.textContent === "Open on Jira")`));
  await page.waitFor(`![...document.querySelectorAll(".work-actions button")].find((b) => b.textContent === "Labels ▾").disabled`, 30_000);
  await sleep(400);
  await page.shot(`${out}/web-issue.png`);

  await click("In Progress ▾");
  await sleep(300);
  ok("the status menu is the workflow's moves",
    await page.eval(`[...document.querySelectorAll("[role=menuitem]")].map((b) => b.textContent.trim()).join(",") === "Send to Review,Stop Progress,Done"`));
  await page.shot(`${out}/web-issue-status.png`);
  await page.eval(`[...document.querySelectorAll("[role=menuitem]")].find((b) => b.textContent.includes("Send to Review")).click()`);
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "In Review ▾")`, 30_000);
  ok(`the move is done: ${await said()}`, (await said()) === "Status changed.");
  await sleep(300);
  await page.shot(`${out}/web-issue-moved.png`);

  await click("Labels ▾");
  await sleep(300);
  await page.eval(`[...document.querySelectorAll("[role=menuitem]")].find((b) => b.textContent.includes("ux")).click()`);
  await page.waitFor(`[...document.querySelectorAll(".work-page-head .work-row-head *")].some((e) => e.textContent === "ux")`, 30_000);
  ok(`a label is added: ${await said()}`, (await said()) === "Labels changed.");

  await page.focus(".work-comment-box textarea");
  await page.type("Fixed by holding the sheet until the payment answers.");
  await click("Comment");
  await page.waitFor(`[...document.querySelectorAll(".work-comment")].some((c) => c.textContent.includes("holding the sheet"))`, 30_000);
  ok("the comment is on the page", true);
  await sleep(300);
  await page.shot(`${out}/web-issue-commented.png`);
} finally {
  await chrome.close();
}
