// The #4098 walk: the azuredevops server's views on the web page, against the fixture Azure
// DevOps (.agents/skills/run-app/scripts/fake-azure-devops.py). Pairs, opens the folder's pinned
// Pull requests, opens a pull request's page in the view, its tabs, a failed build's log, Retry
// Failed Jobs, its Merge question, its Lineage tab and its diff in the page's own diff
// (agents/open-diff); then the list at a phone's width. Merges, approves, retries and comments
// nothing. The browser joins the scratch root's lock with the recovery key its window showed
// (RECOVERY_KEY).
//
//   node Web/test/walk/azuredevops4098.mjs <WEB_URL> <browser code> <folder name> <pr number> <out dir>
//
// Expects the folder's .agents/pins.json to pin ui://azuredevops/pull-requests, and its
// azuredevops server (hosted) approved.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, number, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
// One profile for every run, so a browser the window approved once stays in the lock.
const chrome = await launch({ profile: "/tmp/run-ado4098-chrome" });

/** The session of the frame whose document's title is `title`: a view, inside its sandbox proxy. */
const viewFrame = async (title, timeout = 20_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const { targetInfos } = await chrome.send("Target.getTargets");
    for (const t of targetInfos.filter((t) => t.type === "iframe")) {
      // A frame can go between the list and the read: the next one.
      try {
        const { sessionId } = await chrome.send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
        const { result } = await chrome.send("Runtime.evaluate", { expression: "document.title", returnByValue: true }, sessionId);
        if (result.value === title) return sessionId;
      } catch { /* gone */ }
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
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 30_000);
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
    // What it read before it was in the lock was refused: read it all again.
    await page.eval(`location.reload()`);
    await sleep(3000);
  }
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  // The scratch host's join card names this Mac: no shot shows it (the repo is public).
  await page.eval(`(() => {
    const hide = () => [...document.querySelectorAll(".sidebar *")].filter((e) => e.children.length && e.textContent.includes("Approve the new machine") && !e.querySelector(".row.folder"))
      .slice(-1).forEach((e) => { e.style.display = "none"; });
    hide(); setInterval(hide, 300); })()`);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 10_000);
  const titles = await page.eval(`[...document.querySelectorAll(".sidebar .row.pin .title")].map((t) => t.textContent)`);
  check(titles.includes("Pull requests"), `the pin under the folder: ${js(titles)}`);
  const openPin = async (title) => {
    await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === ${js(title)}).querySelector(".pick").click()`);
    // A view the person has not seen yet waits for their Show first.
    await page.waitFor(`document.querySelector(".view-layer iframe") || [...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`, 15_000);
    if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
    await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
    await sleep(800);
  };

  // Pull requests.
  await openPin("Pull requests");
  let pulls = await viewFrame("Pull requests");
  await waitInView(pulls, `document.querySelectorAll("#prs li:not(.section)").length >= 1`);
  const rows = await inView(pulls, `[...document.querySelectorAll("#prs li:not(.section)")].map((li) => li.textContent.replace(/\\s+/g, " ").trim())`);
  check(rows.length >= 2 && rows.every((r) => /Checks passed|Checks failed|Checks running|No checks/.test(r)), `each pull request says its checks: ${js(rows)}`);
  check(rows.some((r) => r.includes("Your review") && r.includes("Retry")), `a review asked of the viewer, and Retry on a failed build: ${js(rows)}`);
  const sections = await inView(pulls, `[...document.querySelectorAll("#prs li.section")].map((li) => li.textContent.trim())`);
  check(sections.some((s) => /^needs you/i.test(s)), `in sections: ${js(sections)}`);
  await sleep(500);
  await page.shot(`${out}/web-pulls.png`);

  // A pull request's page, in the same view.
  check(await inView(pulls, `(() => { const a = [...document.querySelectorAll("#prs li")].find((li) => li.querySelector("a")?.textContent === "#" + ${js(number)})?.querySelector("a.title"); a?.click(); return !!a; })()`),
    `#${number}'s title opens its page`);
  await waitInView(pulls, `document.querySelector("#page h2")`);
  const head = await inView(pulls, `document.querySelector("#page").textContent`);
  check(head.includes("Conversation") && head.includes("Line comments") && head.includes("Files") && head.includes("Checks") && head.includes("Azure DevOps"),
    "the page has its tabs and its link to Azure DevOps");
  const notes = await inView(pulls, `[...document.querySelectorAll("#page .note")].map((n) => n.textContent)`);
  check(notes.some((n) => n.includes("Apple Pay")) && !notes.some((n) => n.includes("Policy:")), `the conversation, without Azure DevOps's own: ${js(notes)}`);
  await sleep(400);
  await page.shot(`${out}/web-pr-conversation.png`);
  await pressInView(pulls, "Line comments");
  await sleep(400);
  const threads = await inView(pulls, `[...document.querySelectorAll("#page .note .path")].map((p) => p.textContent)`);
  check(threads.some((t) => t.startsWith("src/checkout.ts:3")), `the comments on lines of code, by file and line: ${js(threads)}`);
  await page.shot(`${out}/web-pr-line-comments.png`);
  await pressInView(pulls, "Checks");
  await sleep(400);
  const checks = await inView(pulls, `[...document.querySelectorAll("#page .checks li")].map((li) => li.textContent.replace(/\\s+/g, " ").trim())`);
  check(checks.some((c) => c.includes("shop-pr") && c.includes("Show Log")) && checks.some((c) => c.includes("scan/secrets")),
    `a failed build has Show Log, beside a status: ${js(checks)}`);
  check(await inView(pulls, `[...document.querySelectorAll("#page button")].some((b) => b.textContent === "Retry Failed Jobs")`), "Retry Failed Jobs");
  await pressInView(pulls, "Show Log");
  await waitInView(pulls, `document.querySelector("#page pre.log") && !document.querySelector("#page pre.log").textContent.startsWith("Loading")`);
  const shown = await inView(pulls, `document.querySelector("#page pre.log").textContent`);
  check(shown.includes("1 test failed") && shown.includes("expected saved card"), `Show Log shows the failed step's errors and log: ${js(shown.slice(0, 120))}`);
  await sleep(300);
  await page.shot(`${out}/web-pr-checks.png`);
  await pressInView(pulls, "Merge");
  await sleep(300);
  check(await inView(pulls, `!!document.querySelector("#page .confirm")`), "Merge asks again first");
  await page.shot(`${out}/web-pr-merge-question.png`);
  await pressInView(pulls, "Cancel");
  await pressInView(pulls, "Lineage");
  await waitInView(pulls, `document.querySelector("#page .lineage") && !document.querySelector("#page .lineage").textContent.includes("loading")`);
  const lineage = await inView(pulls, `document.querySelector("#page .lineage").textContent`);
  check(lineage.startsWith("Lineage") && !lineage.includes("keeps none"), `the host answers the Lineage tab: ${js(lineage.slice(0, 120))}`);

  // Its diff, drawn by the page with the Review page's diff.
  await pressInView(pulls, "Files");
  await sleep(300);
  const files = await inView(pulls, `[...document.querySelectorAll("#page .files li")].map((li) => li.textContent)`);
  check(files.includes("src/checkout.ts") && files.includes("src/saved.ts (added)"), `the files and how each changed: ${js(files)}`);
  check(await pressInView(pulls, "Show Diff"), "Files has Show Diff");
  await page.waitFor(`document.querySelector(".view-diff .file-diff .line")`, 15_000);
  const diff = await page.eval(`({ files: [...document.querySelectorAll(".view-diff-file")].map((f) => f.dataset.path),
    added: document.querySelectorAll(".view-diff .file-diff .line.added").length })`);
  check(diff.files.length >= 1 && diff.added >= 1, `the diff, file by file: ${js(diff)}`);
  const open = await page.eval(`[...document.querySelectorAll(".view-diff button")].map((b) => b.textContent).filter((t) => t.startsWith("Open on"))`);
  check(open.length === 1 && open[0] === "Open on Azure DevOps", `the diff names its forge (#4128): ${js(open)}`);
  await sleep(300);
  await page.shot(`${out}/web-pr-diff.png`);
  await page.press("Done");
  await sleep(500);
  pulls = await viewFrame("Pull requests");

  // A phone's width: the pills go under the title.
  await page.viewport(390, 844);
  await pressInView(pulls, "‹ Pull requests");
  await waitInView(pulls, `document.querySelectorAll("#prs li:not(.section)").length >= 1 && !document.querySelector("#list").hidden`);
  await sleep(600);
  await page.shot(`${out}/web-pulls-phone.png`);
  const errors = page.errors.filter((e) => !e.includes("favicon"));
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
