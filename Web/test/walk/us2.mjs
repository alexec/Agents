// The US2 walk (071 quickstart §4, T053): a real Claude turn on a scratch root, watched and
// answered in headless Chrome.
//
//   node Web/test/walk/us2.mjs <WEB_URL> <CONTROL_URL> <operator code> <work folder URL> <out dir>
//
// The operator client stands in for the scratch Mac window: it speaks the window's wire over the
// control plane's TLS address. It starts the turn, as the window's prompt would, and answers the
// last permission itself, so the browser has one answered elsewhere (scenario 5). The browser
// answers the question and the first permission (scenario 4). The lag (SC-003) is measured from
// each agent/entry reaching the operator client to the browser's chat changing after it.

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";
import { Operator } from "./operator.mjs";

const [webURL, controlURL, operatorCode, workURL, out] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };

const op = await Operator.pair(controlURL, operatorCode);
const hosts = await op.call("hosts/list");
const host = hosts.find((h) => h.state === "online")?.id;
if (!host) throw new Error("no host online");

const chrome = await launch({ profile: `/tmp/071-us2-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type((await op.call("clients/startPairing", { grant: "device", kind: "browser" })).text);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

// What the chat says and how many cards it shows, at every change, on the page's clock, which is
// the same wall clock as this script's.
await page.eval(`(() => {
  window.__seen = [];
  new MutationObserver(() => window.__seen.push([Date.now(), document.querySelector(".transcript")?.textContent ?? "",
    document.querySelectorAll(".card").length]))
    .observe(document.body, { subtree: true, childList: true, characterData: true });
})()`);

// What the operator client heard, and when: each chunk of the agent's reply, and each card asked.
const chunks = [];
const asked = [];
let agentID = null;
op.link.onNotification((method, params) => {
  if (params?.agentID !== agentID) return;
  if (method === "agent/entry" && params.entry.kind.agentMessage) chunks.push([Date.now(), params.entry.kind.agentMessage.text]);
  if ((method === "agent/permission" || method === "agent/elicitation") && params.request) asked.push(Date.now());
});

const clickText = (selector, text) => page.eval(`(() => {
  const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)}) && e.offsetParent !== null);
  el?.click();
  return !!el;
})()`);

if (!(await clickText(".projects .row", "work"))) throw new Error("no work project");
await page.waitFor(`document.querySelector(".sessions .section-head")`);

const prompt = [
  "This is a test of answering from a browser. Do exactly these steps, in order, and nothing else:",
  "1. Use your AskUserQuestion tool to ask me which greeting to write, with the options Hello and Howdy.",
  "2. Run this with your Bash tool: echo <the greeting I chose> > greeting.txt",
  "3. Run this with your Bash tool: date > when.txt",
  "4. Say in one sentence what you did.",
].join("\n");
const started = Date.now();
agentID = await op.link.call("agents/start", { runtimeID: "claude", cwd: workURL, prompt }, host);
say(`started ${agentID} from the operator client (the window's path)`);

// The new session, under Working: an earlier walk's may be under Done.
await page.waitFor(`document.querySelector(".group[aria-label=Working] .session")`, 60_000);
await page.shot(`${out}/us2-1-working.png`);
say(`sessions column while it works: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".sessions .subhead")].map((h) => h.textContent)`))}`);
await page.eval(`document.querySelector(".group[aria-label=Working] .session").click()`);
await page.waitFor(`document.querySelector(".chat h1")?.textContent !== "New session"`, 30_000);

// 1. The question, answered in the browser.
await page.waitFor(`document.querySelector(".card[aria-label=Question]")`, 180_000);
await page.shot(`${out}/us2-2-question.png`);
say(`question card: ${JSON.stringify(await page.text(".card[aria-label=Question]"))}`);
say(`title with a question waiting: ${JSON.stringify(await page.eval("document.title"))}`);
if (!(await clickText(".card[aria-label=Question] button", "Howdy"))) throw new Error("no Howdy button");
// A one-click card is answered by the choice; a paged form waits for Submit.
await sleep(300);
if (await clickText(".card[aria-label=Question] button", "Submit")) say("the question was a form: chose Howdy, then Submit");
await page.waitFor(`!document.querySelector(".card[aria-label=Question]")`, 30_000);
say("answered the question in the browser: Howdy");

// 2. The first permission, answered in the browser.
await page.waitFor(`document.querySelector(".card[aria-label='Permission request']")`, 180_000);
await page.shot(`${out}/us2-3-permission.png`);
say(`permission card: ${JSON.stringify(await page.text(".card[aria-label='Permission request']"))}`);
const allowed = await page.eval(`(() => {
  const b = [...document.querySelectorAll(".card[aria-label='Permission request'] button")].find((x) => x.classList.contains("prominent"));
  b?.click(); return b?.textContent ?? null;
})()`);
say(`answered the first permission in the browser: ${allowed}`);
await page.waitFor(`!document.querySelector(".card[aria-label='Permission request']")`, 30_000);

// 3. The second permission, answered by the operator client while the browser shows it.
await page.waitFor(`document.querySelector(".card[aria-label='Permission request']")`, 180_000);
const [pending] = (await op.link.call("permissions/pending", {}, host)).filter((p) => p.agentID === agentID);
const allow = pending.options.find((o) => o.kind === "allow_once");
await op.link.call("permissions/answer", { permissionID: pending.id, optionID: allow.optionID }, host);
await page.waitFor(`document.querySelector(".card .answered")?.textContent.includes("another device")`, 10_000);
await page.shot(`${out}/us2-4-answered-elsewhere.png`);
const inert = await page.eval(`(() => {
  const card = document.querySelector(".card.inert");
  const before = document.querySelectorAll(".card").length;
  card?.querySelector("button")?.click();
  return { inert: !!card, cardsBefore: before };
})()`);
say(`answered by the operator client while shown: the browser says ${JSON.stringify(await page.text(".card .answered"))}; ${JSON.stringify(inert)}`);
await sleep(5_000);
say(`after the note's time: ${await page.eval(`document.querySelectorAll(".card").length`)} cards`);

// 4. The turn carries on to its end.
for (let i = 0; i < 180; i++) {
  const agent = (await op.link.call("agents/list", { includeArchived: false }, host)).find((a) => a.id === agentID);
  if (agent && agent.state !== "running" && agent.state !== "starting" && agent.state !== "waitingOnUser") {
    say(`turn ended: ${agent.state}${agent.report ? `, ${agent.report.outcome}: ${agent.report.message}` : ""} after ${Math.round((Date.now() - started) / 1000)} s`);
    break;
  }
  await sleep(1_000);
}
await sleep(1_500);
await page.shot(`${out}/us2-5-outcome.png`);
say(`sessions column after: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".sessions .subhead")].map((h) => h.textContent)`))}`);
say(`row status: ${JSON.stringify(await page.eval(`document.querySelector(".sessions .session .status")?.getAttribute("aria-label")`))}`);
say(`chat at Outcome: ${JSON.stringify(await page.text(".transcript"))}`);

// 5. The same turn at Steps and at Details (069).
await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "steps"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
await sleep(300);
await page.shot(`${out}/us2-6-steps.png`);
say(`chat at Steps: ${JSON.stringify(await page.text(".transcript"))}`);
await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "details"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
await sleep(300);
await page.shot(`${out}/us2-7-details.png`);
await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "outcome"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);

// What the host recorded: the answers given in the browser, and the files the turn wrote.
const transcript = await op.link.call("agents/transcript", { agentID, limit: 400 }, host);
const answers = transcript.entries.filter((e) => e.kind.elicitationAnswered || e.kind.permissionAnswered)
  .map((e) => e.kind.elicitationAnswered?.summary ?? `permission: ${e.kind.permissionAnswered.optionName ?? e.kind.permissionAnswered.optionID}`);
say(`on the host's record: ${JSON.stringify(answers)}`);

// SC-003: how long after the operator client heard a thing the browser showed it. A reply chunk
// counts once its words are in the chat; a card once it is on the page.
const seen = await page.eval("window.__seen");
const plain = (text) => text.replace(/[*_`#>]/g, "").replace(/\s+/g, " ").trim();
const lags = [];
for (const [at, text] of chunks) {
  const words = plain(text);
  if (words.length < 6) continue;
  const shown = seen.find(([t, chat]) => t >= at - 5 && plain(chat).includes(words));
  if (shown) lags.push(shown[0] - at);
}
for (const at of asked) {
  const shown = seen.find(([t, , cards]) => t >= at - 5 && cards > 0);
  if (shown) lags.push(shown[0] - at);
}
lags.sort((a, b) => a - b);
const median = lags.length ? lags[Math.floor(lags.length / 2)] : null;
say(`lag over ${lags.length} updates (${chunks.length} reply chunks heard, ${asked.length} cards): median ${median} ms, worst ${lags[lags.length - 1]} ms; all ${JSON.stringify(lags)}`);
say(`page errors: ${JSON.stringify(page.errors)}`);

writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
op.stop();
await chrome.close();
