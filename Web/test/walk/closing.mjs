// The closing walk (071 quickstart §8, T071): SC-002's whole list from one headless Chrome at 1440,
// with a real Claude agent on a scratch root, the scratch window put on the session after each
// step, and CDP listening throughout for SC-008: every request the page makes, every console
// call, and what reaches the control plane's log.
//
//   node Web/test/walk/closing.mjs <WEB_URL> <ROOT> <device code> <picture> <out dir> <rpc.py> \
//       <window script> <control script>
//
// `window script` takes `open <agent id>` and `shot <png>`; `control script` takes stop and start.
// Records are read on the host's own socket (rpc.py), as the window reads them.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, root, deviceCode, picture, out, rpcPath, windowScript, control] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const rpc = (...args) => JSON.parse(execFileSync(rpcPath, [root, "call", ...args], { encoding: "utf8" }));
const record = (id) => rpc("agents/list", JSON.stringify({ includeArchived: true })).find((a) => a.id === id);
const window = (...args) => {
  try { execFileSync(windowScript, args, { stdio: "pipe", timeout: 60_000 }); } catch (error) {
    say(`window ${args[0]} failed: ${String(error.stderr ?? error.message).trim().split("\n").pop()}`);
  }
};
const until = async (what, test, seconds = 60) => {
  for (let i = 0; i < seconds * 4; i++) {
    const value = await test();
    if (value) return value;
    await sleep(250);
  }
  throw new Error(`waited ${seconds} s for ${what}`);
};
const ended = (a) => a && !["running", "starting", "waitingOnUser"].includes(a.state);
// The words that must never leave the browser for anywhere but its own socket, or reach a log.
const marker = "periwinkle-7c1f";

const chrome = await launch({ profile: `/tmp/071-closing-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
const clickText = (selector, text) => page.eval(`(() => {
  const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)}) && e.offsetParent !== null);
  el?.click(); return !!el;
})()`);
const choose = (scope, label, value) => page.eval(`(() => {
  const s = document.querySelector(${JSON.stringify(scope)} + ' select[aria-label=${JSON.stringify(label)}]');
  if (!s) return null;
  const option = [...s.options].find((o) => o.value === ${JSON.stringify(value)} || o.textContent.startsWith(${JSON.stringify(value)}));
  if (!option) return null;
  s.value = option.value; s.dispatchEvent(new Event("change", { bubbles: true }));
  return option.textContent;
})()`);
const menu = async (label) => {
  await page.press("More");
  await sleep(150);
  if (!(await clickText("[role=menuitem]", label))) throw new Error(`no ${label} in the menu`);
};
const allowInPage = () => page.eval(`(() => {
  const b = [...document.querySelectorAll(".card[aria-label='Permission request'] button")].find((x) => x.classList.contains("prominent"));
  b?.click(); return b?.textContent ?? null;
})()`);
const tab = (name) => page.eval(`[...document.querySelectorAll(".files [role=tab]")].find((t) => t.textContent === ${JSON.stringify(name)})?.click()`);

// §2. Pair.
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(deviceCode);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);
say(`§2 paired: ${JSON.stringify(await page.eval(`document.querySelector(".identity span")?.textContent ?? ""`))}`);
// Whether an answer on its way was ever drawn as one (#86), on the page's own clock.
await page.eval(`(() => { window.__telling = []; new MutationObserver(() => {
  const t = document.querySelector(".card .telling"); if (t) window.__telling.push(t.textContent);
}).observe(document.body, { subtree: true, childList: true }); })()`);

// 1. Start in a new worktree, with a picture attached.
if (!(await clickText(".projects .row", "work"))) throw new Error("no work project");
await page.waitFor(`document.querySelector(".sessions .section-head")`);
await page.press("New session");
await page.waitFor(`[...document.querySelectorAll("select[aria-label='Works in'] option")].some((o) => o.value === "new")`, 15_000);
say(`works in: ${await choose(".new-agent", "Works in", "new")}`);
await page.waitFor(`document.querySelector(".new-agent .menus") || document.querySelector(".new-agent .failure")`, 60_000);
await page.setFiles(".new-agent input[type=file]", [picture]);
await page.waitFor(`document.querySelector(".attachments li")`, 10_000);
await page.focus(".new-agent textarea[aria-label=Prompt]");
await page.type([
  "This is a test of driving you from a browser. Do exactly these steps, in order, and nothing else:",
  "1. Use your AskUserQuestion tool to ask me which greeting to write, with the options Hello and Howdy.",
  "2. Run this with your Bash tool: echo <the greeting I chose> > greeting.txt",
  "3. Create plan.md in your working folder with a '# Plan' heading and one short paragraph.",
  "4. Call the show_file tool from the agents MCP server on plan.md's absolute path.",
  "5. Add one more short paragraph to plan.md.",
  `6. Say in one sentence what colour the attached picture is, and include the word ${marker}.`,
].join("\n"));
await page.press("Send");
await page.waitFor(`location.hash.includes("/s/")`, 60_000);
const id = await page.eval(`decodeURIComponent(location.hash.split("/s/")[1].split("/")[0])`);
const started = await until("the agent on the record", () => record(id));
say(`start in a worktree: ${id}, worktree ${started.worktree?.name ?? "none"} (${started.worktree?.branch ?? "-"})`);
const first = rpc("agents/transcript", JSON.stringify({ agentID: id, limit: 20 })).entries.find((e) => e.kind.userMessage);
say(`send with an attachment: the first prompt's blocks ${JSON.stringify((first?.kind.userMessage.blocks ?? []).map((b) => b.type))}`);
await page.shot(`${out}/closing-1-started.png`);
window("open", id);
window("shot", `${out}/closing-window-1-started.png`);

// 2. The question, answered in the page.
await page.waitFor(`document.querySelector(".card[aria-label=Question]")`, 180_000);
if (!(await clickText(".card[aria-label=Question] button", "Howdy"))) throw new Error("no Howdy button");
await sleep(300);
if (await clickText(".card[aria-label=Question] button", "Submit")) say("the question was a form: chose Howdy, then Submit");
await page.waitFor(`!document.querySelector(".card[aria-label=Question]")`, 30_000);
say(`answer a question: Howdy; drawn on its way as ${JSON.stringify([...new Set(await page.eval("window.__telling"))])}`);

// 3. Each permission, answered in the page, until the page opens beside the chat.
let allowed = 0;
for (let i = 0; i < 480 && !(await page.eval(`!!document.querySelector(".files .live-page")`)); i++) {
  const a = record(id);
  if (ended(a)) break;
  if (await page.eval(`!!document.querySelector(".card[aria-label='Permission request']:not(.inert)")`)) {
    const name = await page.eval(`document.querySelector(".card[aria-label='Permission request'] .strong")?.textContent`);
    if (await allowInPage()) { allowed++; say(`answer a permission request: allowed "${name}"`); await sleep(800); }
  }
  await sleep(250);
}
window("shot", `${out}/closing-window-2-answered.png`);

// 4. A live page: opened by show_file, followed, typed on.
await page.waitFor(`document.querySelector(".files .live-page .passage")`, 180_000);
say(`a live page: opened on the ${await page.eval(`document.querySelector(".files .tab.chosen")?.textContent`)} tab`);
for (let i = 0; i < 480; i++) {
  const a = record(id);
  if (ended(a)) { say(`the turn ended: ${a.state}${a.report ? `, ${a.report.outcome}: ${a.report.message}` : ""}`); break; }
  if (await page.eval(`!!document.querySelector(".card[aria-label='Permission request']:not(.inert)")`)) {
    if (await allowInPage()) { allowed++; say("answered another permission in the page"); await sleep(800); }
  }
  await sleep(250);
}
await sleep(1500);
const plan = `${started.cwd.replace(/^file:\/\//, "").replace(/\/$/, "")}/plan.md`;
say(`the page draws ${await page.eval(`document.querySelectorAll(".files .passage").length`)} passages; plan.md on disk: ${existsSync(plan)}`);
const typed = " Typed in the browser.";
await page.eval(`[...document.querySelectorAll(".files .passage")].pop().click()`);
await page.waitFor(`document.querySelector(".files .passage-editor")`);
await page.eval(`(() => { const t = document.querySelector(".files .passage-editor"); t.focus(); t.setSelectionRange(t.value.length, t.value.length); })()`);
await page.type(typed);
await until("the typing on disk", () => existsSync(plan) && readFileSync(plan, "utf8").includes(typed.trim()), 15);
await page.eval(`document.querySelector(".files .passage-editor")?.blur()`);
say("typed on the live page: reached plan.md on the host");
await page.shot(`${out}/closing-2-page.png`);

// 5. The changes view and a file.
await tab("Changes");
await page.waitFor(`document.querySelector(".changed-files li")`, 15_000);
say(`the changes view: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".changed-files .row")].map((r) => r.innerText.replace(/\\n/g, " · "))`))}`);
await page.eval(`[...document.querySelectorAll(".changed-files .row")].find((r) => r.textContent.includes("greeting"))?.click()`);
await page.waitFor(`document.querySelector(".diff-line")`, 15_000);
await page.shot(`${out}/closing-3-changes.png`);
await tab("Files");
await page.waitFor(`[...document.querySelectorAll(".entries .row")].some((r) => r.textContent.includes("greeting.txt"))`, 15_000);
await page.eval(`[...document.querySelectorAll(".entries .row")].find((r) => r.textContent.includes("greeting.txt")).click()`);
await page.waitFor(`document.querySelector(".file-text")`, 15_000);
say(`open a file: greeting.txt reads ${JSON.stringify(await page.eval(`document.querySelector(".file-text").textContent.trim()`))}`);
window("shot", `${out}/closing-window-3-done.png`);

// 6. A second turn held on its permission: a prompt queued and sent now, the model changed,
// then stopped and archived.
await page.focus(".chat textarea[aria-label=Prompt]");
await page.type("Run this with your Bash tool: echo three > three.txt. Then say done.");
await page.press("Send");
await page.waitFor(`document.querySelector(".card[aria-label='Permission request']:not(.inert)")`, 180_000);
await page.focus(".chat textarea[aria-label=Prompt]");
await page.type("Also, say the word banana.");
await page.press("Send");
await page.waitFor(`document.querySelector(".queued")`, 20_000);
await clickText(".queued button", "↑ Send now");
await until("the queue to empty", () => (record(id).queuedPrompts?.length ?? 0) === 0, 30);
say("Send now: the queue emptied on the record");
await page.waitFor(`document.querySelector(".chat .menus select[aria-label=Model]")`, 30_000);
const before = record(id).startOptions.values.model;
const models = await page.eval(`[...document.querySelector(".chat select[aria-label=Model]").options].map((o) => o.textContent)`);
const current = await page.eval(`document.querySelector(".chat select[aria-label=Model]").selectedOptions[0]?.textContent`);
const other = models.find((o) => o !== current && o !== "");
await choose(".chat", "Model", other);
const changed = await until("the model on the record", () => {
  const value = record(id).startOptions.values.model;
  return JSON.stringify(value) !== JSON.stringify(before) ? value : null;
}, 30);
say(`change model: ${current} → ${other}; on the record ${JSON.stringify(before)} → ${JSON.stringify(changed)}`);
window("shot", `${out}/closing-window-4-model.png`);
await until("the turn to hold its runtime", () => ["running", "waitingOnUser"].includes(record(id).state), 120);
await menu("Stop");
const stopped = await until("stopped", () => { const a = record(id); return a.state === "stopped" ? a : null; }, 30);
say(`stop: ${stopped.state}, ${stopped.endedReason}`);
window("shot", `${out}/closing-window-5-stopped.png`);
await menu("Archive");
await until("archived", () => record(id).state === "archived", 15);
say("archive: archived on the record");
window("shot", `${out}/closing-window-6-archived.png`);
await page.shot(`${out}/closing-4-archived.png`);

// 7. Run a workflow, and answer its permission in the page.
await page.waitFor(`document.querySelector(".workflows .row.workflow")`, 30_000);
const known = new Set(rpc("agents/list", JSON.stringify({ includeArchived: true })).map((a) => a.id));
await page.press("Run Write a greeting now");
const run = await until("the run on the host", () => rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => !known.has(a.id)), 30);
say(`run a workflow: ${run.id}, started by ${run.startedByWorkflow}`);
await page.eval(`location.hash = location.hash.replace(/\\/s\\/[^/]+/, "/s/${run.id}")`);
for (let i = 0; i < 480; i++) {
  const a = record(run.id);
  if (ended(a)) { say(`the run ended: ${a.state}${a.report ? `, ${a.report.outcome}: ${a.report.message}` : ""}`); break; }
  if (await allowInPage()) { say("answered the run's permission in the page"); await sleep(800); }
  await sleep(250);
}
window("open", run.id);
window("shot", `${out}/closing-window-7-workflow.png`);
await page.shot(`${out}/closing-5-workflow.png`);

// §6. Away and back: the control plane stopped for 15 s and started again, with no reload.
await page.eval("window.__notReloaded = true");
execFileSync(control, ["stop"], { stdio: "pipe" });
const awayAt = Date.now();
await page.waitFor(`document.querySelector(".banner")?.textContent.includes("Can't reach the control plane")`, 15_000);
say(`away: the banner says ${JSON.stringify(await page.text(".banner"))} after ${((Date.now() - awayAt) / 1000).toFixed(1)} s`);
await page.shot(`${out}/closing-6-away.png`);
await sleep(15_000);
execFileSync(control, ["start"], { stdio: "pipe" });
const backAt = Date.now();
await page.waitFor(`!document.querySelector(".banner")`, 30_000);
say(`back: the banner went ${((Date.now() - backAt) / 1000).toFixed(1)} s after the control plane started; not reloaded: ${await page.eval("window.__notReloaded === true")}`);

// SC-008: requests, the console and the control plane's log.
const origin = new URL(webURL).host;
const foreign = page.requests.filter((u) => !u.startsWith(`http://${origin}/`) && !u.startsWith(`ws://${origin}/`) && !u.startsWith("blob:") && !u.startsWith("data:"));
say(`requests: ${page.requests.length}, all to ${origin}: ${foreign.length === 0}${foreign.length ? ` (others: ${JSON.stringify(foreign.slice(0, 5))})` : ""}`);
say(`urls holding the code: ${page.requests.filter((u) => u.includes(deviceCode.slice(0, 16))).length}`);
const secrets = { code: deviceCode, marker, banana: "banana", prompt: "Typed in the browser" };
const consoleText = page.console.join("\n");
const log = readFileSync(`${root}/control/control.log`, "utf8");
for (const [name, secret] of Object.entries(secrets)) {
  say(`${name}: in the console ${consoleText.includes(secret)}, in the control plane's log ${log.includes(secret)}`);
}
say(`console lines: ${page.console.length}, of which not "agents: …": ${page.console.filter((c) => !c.startsWith("agents: ")).length}`);
say(`page errors: ${JSON.stringify(page.errors.filter((e) => !e.includes("ERR_CONNECTION_REFUSED")))}`);
say(`permissions answered in the page: ${allowed} in the first turn`);
writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
writeFileSync(`${out}/requests.txt`, page.requests.join("\n") + "\n");
await chrome.close();
