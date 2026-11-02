// The Work pages' actions (#3130): on a run-app root whose folder is on the fixture GitHub
// (forge3130-github.py, AGENTS_TEST_GITHUB_URL), open issue #12's page and see its actions, open
// its Labels menu and add one, write a comment, close it; open PR #21's page, read its failed
// check's log, open its diff, open the merge menu and merge. Screenshots into <out dir>.
//
//   node Web/test/walk/work3130.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-fw3130-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const click = (text, scope = "button") => page.eval(`[...document.querySelectorAll(${JSON.stringify(scope)})].find((b) => b.textContent.trim() === ${JSON.stringify(text)}).click()`);
const said = () => page.eval(`document.querySelector(".work-actions [role=status]")?.textContent ?? ""`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#12")`);
  await page.waitFor(`document.querySelector(".work-actions") && document.querySelector(".work-comment-box")`, 30_000);
  ok("an issue's page has Start Agent, Close and Labels",
    await page.eval(`["Start Agent", "Close", "Labels ▾"].every((t) => [...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === t))`));
  await page.waitFor(`![...document.querySelectorAll(".work-actions button")].find((b) => b.textContent === "Labels ▾").disabled`, 30_000);
  await sleep(400);
  await page.shot(`${out}/web-issue.png`);

  await click("Labels ▾");
  await sleep(300);
  await page.shot(`${out}/web-issue-labels.png`);
  await page.eval(`[...document.querySelectorAll("[role=menuitem]")].find((b) => b.textContent.includes("checkout")).click()`);
  await page.waitFor(`[...document.querySelectorAll(".work-page-head .work-row-head *")].some((e) => e.textContent === "checkout")`, 30_000);
  ok(`a label is added: ${await said()}`, (await said()) === "Labels changed.");

  await page.focus(".work-comment-box textarea");
  await page.type("Reproduced on Safari 19.1 with a fresh profile.");
  await sleep(200);
  await page.shot(`${out}/web-issue-comment.png`);
  await click("Comment");
  await page.waitFor(`[...document.querySelectorAll(".work-comment")].some((c) => c.textContent.includes("fresh profile"))`, 30_000);
  ok("the comment is on the page", true);

  await click("Close");
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Reopen")`, 30_000);
  ok("Close makes it Reopen", true);
  await sleep(300);
  await page.shot(`${out}/web-issue-closed.png`);

  await page.eval(`location.hash = "#/work/pr/" + encodeURIComponent("github:example/shop#21")`);
  await page.waitFor(`document.querySelector(".split-button") && [...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "test log")`, 30_000);
  ok("a PR's page has Merge, Approve, Rerun failed, Show Diff and the failed check's log",
    await page.eval(`["Squash and merge", "Approve", "Rerun failed", "Show Diff", "test log"].every((t) => [...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === t))`));
  await sleep(400);
  await page.shot(`${out}/web-pr.png`);

  await click("test log");
  await page.waitFor(`document.querySelector(".work-log pre")?.textContent.includes("exit code 1")`, 30_000);
  await sleep(300);
  await page.shot(`${out}/web-pr-log.png`);
  await page.eval(`document.querySelector(".work-log header button").click()`);

  await click("Show Diff");
  await page.waitFor(`document.querySelector(".view-diff")`, 30_000);
  await sleep(500);
  await page.shot(`${out}/web-pr-diff.png`);
  await page.eval(`[...document.querySelectorAll(".view-diff button")].find((b) => b.textContent === "Done").click()`);

  await page.eval(`document.querySelector(".split-button button[aria-label='More ways to merge']").click()`);
  await sleep(300);
  await page.shot(`${out}/web-pr-merge-menu.png`);

  await click("Squash and merge");
  await page.waitFor(`document.querySelector(".work-actions [role=status]")?.textContent === "Merged."`, 30_000);
  await page.waitFor(`!document.querySelector(".split-button")`, 30_000);
  ok("Merge merges it", true);
  await sleep(300);
  await page.shot(`${out}/web-pr-merged.png`);
} finally {
  await chrome.close();
}
