// The US5 walk (071 quickstart §7, second half; T068): a project's workflows listed in headless
// Chrome, one run with Run Now, its session found under the project, in the page and in the
// scratch window.
//
//   node Web/test/walk/us5.mjs <WEB_URL> <ROOT> <device code> <out dir> <rpc.py> <window script>

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, root, deviceCode, out, rpcPath, windowScript] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const rpc = (...args) => JSON.parse(execFileSync(rpcPath, [root, "call", ...args], { encoding: "utf8" }));
const window = (...args) => {
  try { execFileSync(windowScript, args, { stdio: "pipe", timeout: 60_000 }); } catch (error) {
    say(`window ${args[0]} failed: ${String(error.stderr ?? error.message).trim().split("\n").pop()}`);
  }
};

const chrome = await launch({ profile: `/tmp/071-us5-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(deviceCode);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);
await page.eval(`[...document.querySelectorAll(".projects .row")].find((r) => r.textContent.startsWith("work"))?.click()`);

// 1. Listed with their triggers, archived ones folded away.
await page.waitFor(`document.querySelectorAll(".workflows .row.workflow").length >= 2`, 30_000);
const rows = () => page.eval(`[...document.querySelectorAll(".workflows > .row.workflow")].map((r) => ({
  mark: r.querySelector(".workflow-mark").getAttribute("aria-label"),
  name: r.querySelector(".title").textContent,
  what: r.querySelector(".subtitle").textContent,
  run: !!r.querySelector("button.run-now"),
}))`);
say(`listed: ${JSON.stringify(await rows())}`);
say(`folded: ${JSON.stringify(await page.eval(`(() => { const d = document.querySelector(".workflows details.archived"); return d ? { label: d.querySelector("summary").textContent, open: d.open } : null; })()`))}`);
await page.shot(`${out}/us5-1-listed.png`);
await page.eval(`document.querySelector(".workflows details.archived").open = true`);
await sleep(200);
say(`archived, opened: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".workflows details.archived .row.workflow")].map((r) => r.querySelector(".workflow-mark").getAttribute("aria-label") + ": " + r.querySelector(".title").textContent + (r.querySelector("button.run-now") ? " (Run Now)" : ""))`))}`);

// 2. Run Now.
const before = new Set(rpc("agents/list", JSON.stringify({ includeArchived: false })).map((a) => a.id));
const ranAt = Date.now();
await page.press("Run Write a greeting now");
let agent = null;
for (let i = 0; i < 120 && !agent; i++) {
  agent = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => !before.has(a.id)) ?? null;
  if (!agent) await sleep(250);
}
say(`Run Now: a new agent on the host after ${((Date.now() - ranAt) / 1000).toFixed(1)} s: ${agent?.id}, started by ${agent?.startedByWorkflow}, labels ${JSON.stringify((agent?.labels ?? []).map((l) => l.value))}`);
await page.waitFor(`[...document.querySelectorAll(".sessions .session .title")].some((t) => t.textContent.includes(${JSON.stringify(agent.title ?? "")}) )`, 30_000);
say(`its session under the project in the page: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".sessions .group")].map((g) => g.getAttribute("aria-label") + ": " + [...g.querySelectorAll(".session .title")].map((t) => t.textContent).join(", "))`))}`);
await page.shot(`${out}/us5-2-ran.png`);
window("open", agent.id);
window("shot", `${out}/us5-window-1-ran.png`);

// The run asks to write its file: answered in the page, and it finishes.
// Opened by its id, with its permission already waiting: the card must be there on arrival.
await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent("file://${root}/work") + "/s/${agent.id}"`);
for (let i = 0; i < 120 && rpc("permissions/pending").filter((p) => p.agentID === agent.id).length === 0; i++) await sleep(250);
await page.waitFor(`location.hash.includes(${JSON.stringify(agent.id)})`, 5_000);
await sleep(1500);
say(`a permission already pending when the chat opened: shown at once: ${await page.eval(`!!document.querySelector(".card[aria-label='Permission request']")`)}`);
for (let i = 0; i < 240; i++) {
  const now = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => a.id === agent.id);
  const allow = await page.eval(`(() => { const b = [...document.querySelectorAll(".card[aria-label='Permission request'] button.prominent")][0]; b?.click(); return !!b; })()`);
  if (allow) say("answered its permission in the page");
  if (now.state !== "running" && now.state !== "starting" && now.state !== "waitingOnUser") {
    say(`the run ended: ${now.state}${now.report ? `, ${now.report.outcome}: ${now.report.message}` : ""}`);
    break;
  }
  await sleep(500);
}
const greeting = `${root}/work/greeting.txt`;
say(`greeting.txt: ${existsSync(greeting) ? JSON.stringify(readFileSync(greeting, "utf8").trim()) : "missing"}`);
await sleep(1000);
say(`the row after: ${JSON.stringify((await rows()).find((r) => r.name === "Write a greeting"))}`);
await page.shot(`${out}/us5-3-done.png`);
window("shot", `${out}/us5-window-2-done.png`);
say(`page errors: ${JSON.stringify(page.errors)}`);
writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
await chrome.close();
