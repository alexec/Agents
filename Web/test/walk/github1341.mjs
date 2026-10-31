// The #1341 walk: the github server's views on the web page. Pairs, opens the folder's pinned
// Pull requests, opens a pull request's page in the view, its tabs, and its diff in the page's own
// diff (agents/open-diff); then the pinned Issues and Start Agent. Reaches into the views' frames
// as CDP targets: each is a frame of its own origin. Merges, approves and comments nothing.
//
//   node Web/test/walk/github1341.mjs <WEB_URL> <browser code> <folder name> <pr number> <out dir>
//
// Expects the folder's .agents/pins.json to pin ui://github/pulls and ui://github/issues, and
// its github server approved and its views shown.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, number, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1341-github-chrome-${process.pid}` });

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
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 2`, 10_000);
  const titles = await page.eval(`[...document.querySelectorAll(".sidebar .row.pin .title")].map((t) => t.textContent)`);
  check(titles.includes("Pull requests") && titles.includes("Issues"), `the two pins under the folder: ${js(titles)}`);

  // Pull requests.
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === "Pull requests").querySelector(".pick").click()`);
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  const pulls = await viewFrame("Pull requests");
  await waitInView(pulls, `document.querySelectorAll("#prs li").length >= 1`);
  const rows = await inView(pulls, `[...document.querySelectorAll("#prs li")].map((li) => li.textContent.replace(/\\s+/g, " ").trim())`);
  check(rows.length >= 1 && rows.every((r) => /Passing|Failing|Running|No checks/.test(r)), `each pull request says its checks: ${js(rows)}`);
  await sleep(500);
  await page.shot(`${out}/web-1-pulls.png`);

  // A pull request's page, in the same view.
  check(await inView(pulls, `(() => { const a = [...document.querySelectorAll("#prs li")].find((li) => li.querySelector("a").textContent === "#" + ${js(number)})?.querySelector("a.title"); a?.click(); return !!a; })()`),
    `#${number}'s title opens its page`);
  await waitInView(pulls, `document.querySelector("#page h2")`);
  const head = await inView(pulls, `document.querySelector("#page").textContent`);
  check(head.includes("Conversation") && head.includes("Review comments") && head.includes("Files") && head.includes("Checks"), "the page has its four tabs");
  check(await inView(pulls, `[...document.querySelectorAll("#page .note .pill")].some((p) => p.textContent === "bot")`), "an app's comment is marked bot");
  check(!(await inView(pulls, `document.querySelector("#page").textContent.includes("<!--")`)), "no HTML comments in the words");
  await sleep(400);
  await page.shot(`${out}/web-2-pr-conversation.png`);
  await pressInView(pulls, "Review comments");
  await sleep(400);
  const threads = await inView(pulls, `[...document.querySelectorAll("#page .note .path")].map((p) => p.textContent)`);
  check(threads.length >= 1, `the comments on lines of code, by file and line: ${js(threads)}`);
  await page.shot(`${out}/web-3-pr-review.png`);
  await pressInView(pulls, "Checks");
  await sleep(400);
  await page.shot(`${out}/web-4-pr-checks.png`);
  await pressInView(pulls, "Merge");
  await sleep(300);
  check(await inView(pulls, `!!document.querySelector("#page .confirm")`), "Merge asks again first");
  await pressInView(pulls, "Cancel");

  // Its diff, drawn by the page with the Review page's diff.
  await pressInView(pulls, "Files");
  await sleep(300);
  check(await pressInView(pulls, "Show Diff"), "Files has Show Diff");
  await page.waitFor(`document.querySelector(".view-diff .file-diff .line")`, 15_000);
  const diff = await page.eval(`({ title: document.querySelector(".view-diff h1").textContent,
    files: [...document.querySelectorAll(".view-diff-file")].map((f) => f.dataset.path),
    added: document.querySelectorAll(".view-diff .file-diff .line.added").length })`);
  check(diff.files.length >= 1 && diff.added >= 1, `the diff, file by file: ${js(diff)}`);
  await sleep(300);
  await page.shot(`${out}/web-5-pr-diff.png`);
  await page.press("Done");
  await sleep(200);
  check(!(await page.eval(`!!document.querySelector(".view-diff")`)), "Done closes the diff");
  await page.viewport(390, 844);
  await sleep(500);
  await pressInView(pulls, "Show Diff");
  await page.waitFor(`document.querySelector(".view-diff .file-diff .line")`, 15_000);
  check(await page.eval(`!!document.querySelector(".view-diff .file-diff.unified")`), "a phone's width shows it unified");
  await sleep(300);
  await page.shot(`${out}/web-6-pr-diff-phone.png`);
  await page.key("Escape");
  await page.viewport(1440, 900);

  // Issues, and Start Agent.
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === "Issues").querySelector(".pick").click()`);
  await sleep(1500);
  if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  const issues = await viewFrame("Issues");
  await waitInView(issues, `document.querySelector("#state") && !/Waiting|Listing/.test(document.querySelector("#state").textContent)`);
  const state = await inView(issues, `document.querySelector("#state").textContent`);
  const count = await inView(issues, `document.querySelectorAll("#issues li").length`);
  check(/open|No open issues/.test(state), `the issues view says what it found: ${state} (${count})`);
  await sleep(400);
  await page.shot(`${out}/web-7-issues.png`);
  if (count) {
    await pressInView(issues, "Start Agent");
    await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes("Work on GitHub issue"))`, 10_000);
    check(true, "Start Agent opens the new-agent form, filled in");
    await page.shot(`${out}/web-8-start-agent.png`);
  }
  const errors = page.errors.filter((e) => !e.includes("favicon"));
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
