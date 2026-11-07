// Bitbucket in the Work pages (#3786): on a run-app root whose folder's remote is
// git@bitbucket.org:agentstest/agents-walk.git, with the host's Bitbucket connection made at a fake
// Bitbucket (BITBUCKET_API_URL), open Work ▸ Issues and Pull requests and see the repository's items;
// open issue #1 (its description as Markdown, its comments, Open on Bitbucket, Start Agent, Close and
// Labels) and write a comment; open pull request #3 (its checks, Merge, Rerun failed, Show Diff) and
// show its diff. Screenshots into <out dir>. The browser joins the scratch root's lock with the
// recovery key its window showed (RECOVERY_KEY), when it asks.
//
//   node Web/test/walk/work3786.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-bb3786-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const click = (text, scope = "button") => page.eval(`[...document.querySelectorAll(${JSON.stringify(scope)})].find((b) => b.textContent.trim() === ${JSON.stringify(text)}).click()`);
const rows = () => page.eval(`[...document.querySelectorAll(".work-row")].map((r) => r.textContent.replace(/\\s+/g, " ").trim())`);
const asked = `document.body.innerText.includes("Approve this device")`;

/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
async function joinLock() {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  // What it read before it was in the lock was refused: read it all again.
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
}

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await joinLock();
  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length >= 2`, 30_000);
  const issues = await rows();
  ok(`the Bitbucket issues are listed: ${issues.join(" | ")}`, issues.some((r) => r.includes("Export the walk as Markdown")) && issues.some((r) => r.includes("Crash on an empty folder")));
  ok("its repository is a choice of the Repo filter", await page.eval(`[...document.querySelectorAll(".work-filters option")].some((o) => o.textContent.includes("agentstest/agents-walk"))`));
  await sleep(400);
  await page.shot(`${out}/web-issues.png`);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("bitbucket:agentstest/agents-walk#1")`);
  await page.waitFor(`document.querySelector(".work-actions") && document.querySelector(".work-comment-box")`, 30_000);
  ok("the page has Start Agent, Close and Labels", await page.eval(`(() => { const t = [...document.querySelectorAll(".work-actions button")].map((b) => b.textContent);
      return ["Start Agent", "Close", "Labels ▾"].every((x) => t.includes(x)); })()`));
  ok("Open on Bitbucket", await page.eval(`[...document.querySelectorAll("a")].some((a) => a.textContent === "Open on Bitbucket")`));
  ok("the description is Markdown, drawn", await page.eval(`[...document.querySelectorAll("strong")].some((b) => b.textContent === "bold")`));
  await page.focus(".work-comment-box textarea");
  await page.type("Written on the web page.");
  await click("Comment");
  await page.waitFor(`[...document.querySelectorAll(".work-comment")].some((c) => c.textContent.includes("Written on the web page."))`, 30_000);
  ok("the comment is on the page", true);
  await sleep(400);
  await page.shot(`${out}/web-issue.png`);

  await page.eval(`location.hash = "#/work/pr"`);
  await page.waitFor(`[...document.querySelectorAll(".work-row")].some((r) => r.textContent.includes("Add a hello file"))`, 30_000);
  ok(`the Bitbucket pull requests are listed: ${(await rows()).join(" | ")}`, true);
  await sleep(400);
  await page.shot(`${out}/web-pulls.png`);

  await page.eval(`location.hash = "#/work/pr/" + encodeURIComponent("bitbucket:agentstest/agents-walk#3")`);
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Show Diff")`, 30_000);
  ok("the page has Rerun failed and Show Diff", await page.eval(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Rerun failed")`));
  await sleep(400);
  await page.shot(`${out}/web-pull.png`);

  await click("Show Diff");
  await page.waitFor(`document.querySelector(".view-diff-file")`, 30_000);
  ok("the diff says Open on Bitbucket", await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Open on Bitbucket")`));
  await sleep(400);
  await page.shot(`${out}/web-pull-diff.png`);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 400)}`);
  throw e;
} finally {
  await chrome.close();
}
