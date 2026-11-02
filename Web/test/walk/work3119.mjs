// Work (#3119): on a run-app root whose folder's repo is on a fixture GitHub (AGENTS_TEST_GITHUB_URL)
// and has issues, PRs and sessions linked by lineage/link, open Work ▸ Issues, filter by a label, open
// Pull requests, open an issue's page (body, comments, lineage, graph), follow a link to its PR's page,
// go Back, and open a page no agent touched. Screenshots into <out dir>.
//
//   node Web/test/walk/work3119.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/w3119-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 1000 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const titles = () => page.eval(`[...document.querySelectorAll(".work-row .work-title")].map((t) => t.textContent)`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length > 0`, 30_000);
  ok(`Issues lists the open issues: ${await titles()}`, (await titles()).length === 3);
  ok("a row an agent worked on says so", await page.eval(`[...document.querySelectorAll(".work-figures")].some((f) => f.textContent.includes("session"))`));
  ok("a row no agent worked on says that", await page.eval(`[...document.querySelectorAll(".work-figures")].some((f) => f.textContent === "No agent yet")`));
  await sleep(400);
  await page.shot(`${out}/web-issues.png`);

  await page.eval(`(() => { const s = [...document.querySelectorAll(".work-filters label")].find((l) => l.textContent.startsWith("Label")).querySelector("select");
    s.value = "ui"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await sleep(300);
  ok(`the ui label leaves two: ${await titles()}`, (await titles()).length === 2);
  await page.shot(`${out}/web-issues-filtered.png`);

  await page.eval(`location.hash = "#/work/pr"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length > 0 && [...document.querySelectorAll(".work-title")].some((t) => t.textContent.includes("checkout"))`, 30_000);
  await sleep(400);
  await page.shot(`${out}/web-pulls.png`);

  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length > 0`, 30_000);
  await page.eval(`[...document.querySelectorAll(".work-row")].find((r) => r.textContent.includes("Safari")).click()`);
  await page.waitFor(`document.querySelector(".work-comment") && document.querySelector(".work-links") && document.querySelector(".lineage-graph")`, 30_000);
  ok(`the page's address: ${await page.eval("location.hash")}`, (await page.eval("location.hash")) === "#/work/issue/github%3Aexample%2Fshop%2312");
  await sleep(800);
  await page.shot(`${out}/web-issue-page.png`);
  await page.eval(`document.querySelector(".work-lineage").scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-issue-lineage.png`);

  console.log("links:", await page.eval(`[...document.querySelectorAll(".work-links button")].map((b) => b.textContent).join(" | ")`));
  await page.eval(`[...document.querySelectorAll(".work-links button")].find((b) => b.textContent.toLowerCase().includes("(pull request)")).click()`);
  await page.waitFor(`location.hash.startsWith("#/work/pr/") && document.querySelector(".work-page-head")?.textContent.includes("Checks")`, 30_000);
  ok("a link opens the PR's page, with its checks and review", true);
  await sleep(600);
  await page.shot(`${out}/web-pr-page.png`);

  await page.press("Back");
  await page.waitFor(`location.hash === "#/work/issue/github%3Aexample%2Fshop%2312"`, 30_000);
  ok("Back goes to the issue", true);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#17")`);
  await page.waitFor(`document.querySelector(".work-lineage .hint")?.textContent === "No agent has worked on this yet."`, 30_000);
  ok("a page no agent touched says so", true);
  await sleep(400);
  await page.shot(`${out}/web-no-agent.png`);

  await page.eval(`location.hash = "#/work/milestone"`);
  await sleep(2500);
  await page.shot(`${out}/web-milestones.png`);
} finally {
  await chrome.close();
}
