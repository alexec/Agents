// The #3826 walk: the azureboards server's Azure Boards page on the web page. Pairs, opens the
// folder's pinned Azure Boards work items, sees them in their sections, narrows them to a state
// category, expands a work item for its description and its Lineage section, and presses Start
// Agent, which opens the new-agent form filled in. Starts no agent. Expects the folder's
// .agents/mcp.json to have the azureboards server (hosted, approved) pointed at the fixture Azure
// DevOps (.agents/skills/run-app/scripts/fake-azure-devops.py, AZURE_BOARDS_PROJECT=acme/Web Shop), and
// ui://azureboards/issues pinned.
//
//   [RECOVERY_KEY=…] node Web/test/walk/views3826-azureboards.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
// One profile for every run, so a browser the window approved once stays in the lock.
const chrome = await launch({ profile: "/tmp/run-ab3826-chrome" });
const title = "Azure Boards work items";

const viewFrame = async (timeout = 20_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const { targetInfos } = await chrome.send("Target.getTargets");
    for (const t of targetInfos.filter((t) => t.type === "iframe")) {
      const { sessionId } = await chrome.send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
      const { result } = await chrome.send("Runtime.evaluate", { expression: "document.title", returnByValue: true }, sessionId);
      if (result.value === title) return sessionId;
    }
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
const listed = (session) => waitInView(session, `!/Waiting|Listing/.test(document.querySelector("#state-line").textContent)`);
const rows = (view) => inView(view, `[...document.querySelectorAll("#issues li.issue-row")].map((li) => li.querySelector("a").textContent)`);

let page;
try {
  page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".nav-item")`, 30_000);
  if (await page.eval(`!document.querySelector(".nav-item")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  // A new browser joins the machine lock (#3490): the scratch window approves it meanwhile.
  for (let i = 0; i < 10 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await sleep(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    if (process.env.RECOVERY_KEY) {
      // Or with the recovery key the scratch window showed.
      await page.press("Use Recovery Key");
      await page.waitFor(`document.querySelector("#lock-recovery-key")`);
      await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
      await page.type(process.env.RECOVERY_KEY);
      await page.press("Use");
    } else console.log("approve this browser in the window: press its Compare Digits");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
    // What it read before it was in the lock was refused: read it all again.
    await page.eval(`location.reload()`);
    await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
    await page.eval(`location.hash = "#/agents"`);
  }
  // A new folder starts folded: unfold it, as its chevron does.
  await page.waitFor(`document.querySelector('.sidebar button.disclosure[aria-label="Unfold work"]')`, 15_000);
  await page.eval(`document.querySelector('.sidebar button.disclosure[aria-label="Unfold work"]').click()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 15_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === ${js(title)}).querySelector(".pick").click()`);
  await sleep(1500);
  if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  const view = await viewFrame();
  await listed(view);
  const state = await inView(view, `document.querySelector("#state-line").textContent`);
  check(/4 open · 2 in progress/.test(state), `the state line: ${state}`);
  const keys = await rows(view);
  check(js(keys) === js(["AB#41", "AB#42", "AB#43", "AB#40"]), `Needs you, Yours, then Team, each changed last first: ${js(keys)}`);
  const types = await inView(view, `[...document.querySelectorAll("#type option")].map((o) => o.textContent)`);
  check(js(types) === js(["Every type", "Bug", "Epic", "Task", "User Story"]), `the type choice: ${js(types)}`);
  const pills = await inView(view, `[...document.querySelectorAll("#issues li.issue-row")][0].querySelector(".meta").textContent`);
  check(/Bug/.test(pills) && /Active/.test(pills) && /payments/.test(pills), `a row's type, state and tags: ${js(pills)}`);
  await sleep(300);
  await page.shot(`${out}/web-issues.png`);

  await inView(view, `(() => { const s = document.querySelector("#category"); s.value = "Proposed"; s.onchange(); return true; })()`);
  await listed(view);
  check(js(await rows(view)) === js(["AB#42"]), `a state category narrows it: ${js(await rows(view))}`);
  await inView(view, `(() => { const s = document.querySelector("#category"); s.value = ""; s.onchange(); return true; })()`);
  await listed(view);

  await inView(view, `document.querySelector("#issues li.issue-row").click()`);
  await waitInView(view, `document.querySelector(".issue-details:not([hidden]) .issue-body h3")`);
  const lineage = await inView(view, `document.querySelector(".issue-details:not([hidden])").textContent`);
  check(/Steps/.test(lineage) && /Lineage/.test(lineage), `a row expands to its description and its Lineage section: ${js(lineage.slice(0, 160))}`);
  await waitInView(view, `!/Loading/.test(document.querySelector(".issue-details:not([hidden])").textContent)`).catch(() => {});
  await sleep(500);
  await page.shot(`${out}/web-issue-expanded.png`);

  await inView(view, `[...document.querySelectorAll("button")].find((b) => b.textContent === "Start Agent").click()`);
  await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes("Work on this Azure Boards"))`, 10_000);
  const prompt = await page.eval(`[...document.querySelectorAll("textarea")].find((t) => t.value.includes("Work on this Azure Boards")).value`);
  check(/^AB#41: /.test(prompt) && /branch name/.test(prompt), `Start Agent opens the new-agent form, filled in: ${js(prompt.split("\n")[0])}`);
  await sleep(300);
  await page.shot(`${out}/web-start-agent.png`);
  const errors = page.errors.filter((e) => !e.includes("favicon"));
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} catch (e) {
  // What the page showed when it stopped, for the reader.
  if (page) await page.shot(`${out}/web-failed.png`).catch(() => {});
  check(false, e.message);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
