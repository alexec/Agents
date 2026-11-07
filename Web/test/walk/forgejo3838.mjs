// The #3838 walk: the forgejo server's views on the web page, against a scratch Forgejo in a
// container. Pairs, opens the folder's pinned Pull requests, opens a pull request's page in the
// view, its tabs, its Merge question and its diff in the page's own diff (agents/open-diff); then
// the pinned Issues, a row's description and Start Agent. Merges, approves and comments nothing.
//
//   node Web/test/walk/forgejo3838.mjs <WEB_URL> <browser code> <folder name> <pr number> <out dir>
//
// Expects the folder's .agents/pins.json to pin ui://forgejo/pull-requests and
// ui://forgejo/issues, and its forgejo server approved.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, number, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
// One profile for every run, so a browser the window approved once stays in the lock.
const chrome = await launch({ profile: "/tmp/run-fj3838-chrome" });

/** The session of the frame whose document's title is `title`: a view, inside its sandbox proxy. */
const viewFrame = async (title, timeout = 20_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const { targetInfos } = await chrome.send("Target.getTargets");
    for (const t of targetInfos.filter((t) => t.type === "iframe")) {
      const { sessionId } = await chrome.send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
      const { result } = await chrome.send("Runtime.evaluate", { expression: "document.title", returnByValue: true }, sessionId);
      if (result.value === title) return sessionId;
    }
    // A view in the proxy's own process is not a target of its own: look in each frame's world.
    await sleep(300);
  }
  throw new Error(`no view frame titled ${title}`);
};
const inView = async (session, expression) => {
  const { result, exceptionDetails } = await chrome.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, session);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  return result.value;
};
const waitInView = async (session, expression, timeout = 15_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await inView(session, `Boolean(${expression})`).catch(() => false)) return;
    await sleep(100);
  }
  throw new Error(`waited ${timeout} ms in the view for ${expression}`);
};
const pressInView = (session, words) => inView(session, `(() => {
  const b = [...document.querySelectorAll("button, a")].find((b) => b.textContent.trim().startsWith(${js(words)}));
  if (!b) return false;
  b.click();
  return true;
})()`);

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
    await sleep(2000);
  }
  await page.eval(`location.hash = "#/agents"`);
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  for (let i = 0; i < 15 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await sleep(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  }
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 2`, 10_000);
  const titles = await page.eval(`[...document.querySelectorAll(".sidebar .row.pin .title")].map((t) => t.textContent)`);
  check(titles.includes("Pull requests") && titles.includes("Issues"), `the pins under the folder: ${js(titles)}`);
  const openPin = async (title) => {
    await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === ${js(title)}).querySelector(".pick").click()`);
    await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
    await sleep(800);
    if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  };

  // Pull requests.
  await openPin("Pull requests");
  const pulls = await viewFrame("Pull requests");
  await waitInView(pulls, `document.querySelectorAll("#prs li:not(.section)").length >= 1`);
  const rows = await inView(pulls, `[...document.querySelectorAll("#prs li:not(.section)")].map((li) => li.textContent.replace(/\\s+/g, " ").trim())`);
  check(rows.length >= 2 && rows.every((r) => /Checks passed|Checks failed|Checks running|No checks/.test(r)), `each pull request says its checks: ${js(rows)}`);
  const sections = await inView(pulls, `[...document.querySelectorAll("#prs li.section")].map((li) => li.textContent.trim())`);
  check(sections.some((s) => s.startsWith("Needs you")), `in sections: ${js(sections)}`);
  await sleep(500);
  await page.shot(`${out}/web-pulls.png`);

  // A pull request's page, in the same view.
  check(await inView(pulls, `(() => { const a = [...document.querySelectorAll("#prs li")].find((li) => li.querySelector("a")?.textContent === "#" + ${js(number)})?.querySelector("a.title"); a?.click(); return !!a; })()`),
    `#${number}'s title opens its page`);
  await waitInView(pulls, `document.querySelector("#page h2")`);
  const head = await inView(pulls, `document.querySelector("#page").textContent`);
  check(head.includes("Conversation") && head.includes("Line comments") && head.includes("Files") && head.includes("Checks"), "the page has its tabs");
  await sleep(400);
  await page.shot(`${out}/web-pr-conversation.png`);
  await pressInView(pulls, "Line comments");
  await sleep(400);
  const threads = await inView(pulls, `[...document.querySelectorAll("#page .note .path")].map((p) => p.textContent)`);
  check(threads.length >= 1, `the comments on lines of code, by file and line: ${js(threads)}`);
  await page.shot(`${out}/web-pr-line-comments.png`);
  await pressInView(pulls, "Checks");
  await sleep(400);
  const checks = await inView(pulls, `[...document.querySelectorAll("#page .checks li")].map((li) => li.textContent.replace(/\\s+/g, " ").trim())`);
  check(checks.some((c) => c.includes("Show Log")), `a failed Actions run has Show Log: ${js(checks)}`);
  await page.shot(`${out}/web-pr-checks.png`);
  await pressInView(pulls, "Merge");
  await sleep(300);
  check(await inView(pulls, `!!document.querySelector("#page .confirm")`), "Merge asks again first");
  await page.shot(`${out}/web-pr-merge-question.png`);
  await pressInView(pulls, "Cancel");

  // Its diff, drawn by the page with the Review page's diff.
  await pressInView(pulls, "Files");
  await sleep(300);
  check(await pressInView(pulls, "Show Diff"), "Files has Show Diff");
  await page.waitFor(`document.querySelector(".view-diff .file-diff .line")`, 15_000);
  const diff = await page.eval(`({ files: [...document.querySelectorAll(".view-diff-file")].map((f) => f.dataset.path),
    added: document.querySelectorAll(".view-diff .file-diff .line.added").length })`);
  check(diff.files.length >= 1 && diff.added >= 1, `the diff, file by file: ${js(diff)}`);
  await sleep(300);
  await page.shot(`${out}/web-pr-diff.png`);
  await page.press("Done");
  await sleep(200);

  // A phone's width: the pills go under the title.
  await page.viewport(390, 844);
  await pressInView(pulls, "‹ Pull requests");
  await waitInView(pulls, `document.querySelectorAll("#prs li:not(.section)").length >= 1 && !document.querySelector("#list").hidden`);
  await sleep(600);
  await page.shot(`${out}/web-pulls-phone.png`);
  await page.viewport(1440, 900);

  // Issues, a row's description, and Start Agent.
  await openPin("Issues");
  const issues = await viewFrame("Issues");
  await waitInView(issues, `document.querySelector("#state") && !/Waiting|Listing/.test(document.querySelector("#state").textContent)`);
  const count = await inView(issues, `document.querySelectorAll("#issues li.issue-row").length`);
  check(count >= 3, `the issues: ${count}`);
  await inView(issues, `[...document.querySelectorAll("#issues li.issue-row")].find((li) => li.textContent.includes("empty list")).click()`);
  await waitInView(issues, `document.querySelector(".issue-body strong")`);
  await sleep(500);
  await page.shot(`${out}/web-issues.png`);
  await pressInView(issues, "Start Agent");
  await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes("Work on this Forgejo issue"))`, 10_000);
  check(true, "Start Agent opens the new-agent form, filled in");
  await page.shot(`${out}/web-start-agent.png`);
  const errors = page.errors.filter((e) => !e.includes("favicon"));
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
