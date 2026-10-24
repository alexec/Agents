// The #1343 walk: the linear server's Linear issues page on the web page. Pairs, opens the
// folder's pinned Linear issues, narrows it to a team and a state, and presses Start Agent,
// which opens the new-agent form filled in. Starts no agent. Expects the folder's
// .agents/pins.json to pin ui://linear/issues and its linear server approved, pointed at a
// stand-in Linear (Web/test/walk/fake-linear.mjs).
//
//   node Web/test/walk/linear1343.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1343-linear-chrome-${process.pid}` });

const viewFrame = async (title, timeout = 20_000) => {
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

let page;
try {
  page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  // A new folder starts folded: unfold it, as its chevron does.
  await page.waitFor(`document.querySelector('.sidebar button.disclosure[aria-label="Unfold work"]')`, 15_000);
  await page.eval(`document.querySelector('.sidebar button.disclosure[aria-label="Unfold work"]').click()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 15_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === "Linear issues").querySelector(".pick").click()`);
  await sleep(1500);
  if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  const view = await viewFrame("Linear issues");
  await listed(view);
  const state = await inView(view, `document.querySelector("#state-line").textContent`);
  const rows = await inView(view, `[...document.querySelectorAll("#issues li")].map((li) => li.querySelector("a").textContent)`);
  check(/2 open · 1 in progress/.test(state) && js(rows) === js(["ENG-7", "ENG-5"]), `the page lists the open issues, newest updated first: ${state} ${js(rows)}`);
  const teams = await inView(view, `[...document.querySelectorAll("#team option")].map((o) => o.textContent)`);
  check(teams.includes("Engineering (ENG)") && teams.includes("Design (DES)"), `the team choice: ${js(teams)}`);
  await sleep(300);
  await page.shot(`${out}/web-1-linear-issues.png`);

  await inView(view, `(() => { const s = document.querySelector("#team"); s.value = "ENG"; s.onchange(); return true; })()`);
  await listed(view);
  await inView(view, `(() => { const s = document.querySelector("#state"); s.value = "started"; s.onchange(); return true; })()`);
  await listed(view);
  check(await inView(view, `document.querySelector("#team").value === "ENG" && document.querySelector("#state").value === "started"`),
    "a team and a state narrow it, and stay chosen");

  await inView(view, `[...document.querySelectorAll("button")].find((b) => b.textContent === "Start Agent").click()`);
  await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes("Work on Linear issue"))`, 10_000);
  const prompt = await page.eval(`[...document.querySelectorAll("textarea")].find((t) => t.value.includes("Work on Linear issue")).value`);
  check(/ENG-7/.test(prompt) && /branch name/.test(prompt), `Start Agent opens the new-agent form, filled in: ${js(prompt.split("\n")[0])}`);
  await page.shot(`${out}/web-2-start-agent.png`);
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
