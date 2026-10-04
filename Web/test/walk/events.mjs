// #170: what one event costs the page, on a large root (5,000 agents, 50 projects), in headless
// Chrome. The page is paired, five projects are unfolded with one Archived fold open, and then:
//   sidebar  N label changes to agents across every project (agent/changed per change);
//   chat     a demo agent's chat open while it is prompted again and again (agent/entry).
// For each, the main thread's script and task time per event, the DOM mutations per event, and
// the heap and node count after a collection. Needs the host started with AGENTS_TEST_RUNTIME=echo.
//
//   node Web/test/walk/events.mjs <WEB_URL> <browser code> <ROOT> <out file> [label]

import { createConnection } from "node:net";
import { appendFileSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out, label = ""] = process.argv.slice(2);
const changes = 200;
const warmPrompts = 250;
const prompts = 50;
const say = (line) => { console.log(line); appendFileSync(out, line + "\n"); };

// The host's own socket: one JSON-RPC object per line.
function daemon(path) {
  const socket = createConnection(path);
  let buffer = "";
  let next = 1;
  const waiting = new Map();
  const listeners = [];
  socket.on("data", (data) => {
    buffer += data;
    let at;
    while ((at = buffer.indexOf("\n")) >= 0) {
      const message = JSON.parse(buffer.slice(0, at));
      buffer = buffer.slice(at + 1);
      if (message.id !== undefined && waiting.has(message.id)) {
        const { resolve, reject } = waiting.get(message.id);
        waiting.delete(message.id);
        if (message.error) reject(new Error(`${message.error.code} ${message.error.message}`)); else resolve(message.result);
      } else if (message.method) for (const listener of listeners) listener(message.method, message.params);
    }
  });
  return {
    ready: new Promise((resolve) => socket.on("connect", resolve)),
    call: (method, params) => new Promise((resolve, reject) => {
      const id = next++;
      waiting.set(id, { resolve, reject });
      socket.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    }),
    on: (listener) => listeners.push(listener),
    close: () => socket.end(),
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const host = daemon(`${root}/daemon.sock`);
await host.ready;

const chrome = await launch({ profile: `/tmp/w170-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.cdp("Performance.enable", { timeDomain: "threadTicks" });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`document.querySelectorAll(".project-fold").length >= 50`, 60_000);
await sleep(2000);

const projects = (await host.call("projects/list", { includeArchived: false })).map((p) => p.project.folder).sort();
const live = await host.call("agents/list", { lean: true, includeArchived: false });

// Five projects unfolded, the first's Archived fold open too.
for (const folder of projects.slice(0, 5)) {
  await page.eval(`document.querySelector('.project-fold[data-folder="${folder}"] .disclosure')?.click()`);
}
await sleep(500);
await page.eval(`(() => { const d = document.querySelector('.project-fold[data-folder="${projects[0]}"] details.archived'); if (d) { d.open = true; d.dispatchEvent(new Event("toggle")); } })()`);
await sleep(2000);

async function metrics() {
  const { metrics: list } = await page.cdp("Performance.getMetrics");
  return Object.fromEntries(list.map((m) => [m.name, m.value]));
}

async function settled() {
  await page.cdp("HeapProfiler.collectGarbage");
  await sleep(300);
  const m = await metrics();
  return { heapMB: (m.JSHeapUsedSize / 1048576).toFixed(1), nodes: m.Nodes, rows: await page.eval(`document.querySelectorAll(".row.session, .turn").length`) };
}

await page.eval(`window.__mutations = 0; new MutationObserver((records) => { window.__mutations += records.length; }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true })`);

/** Runs `drive`, which makes `count` events, and says what they cost the page, each. */
async function measure(name, count, drive) {
  await sleep(1000);
  const before = await metrics();
  const mutationsBefore = await page.eval("window.__mutations");
  const started = Date.now();
  await drive();
  await sleep(1500);
  const after = await metrics();
  const mutations = (await page.eval("window.__mutations")) - mutationsBefore;
  const per = (key) => ((after[key] - before[key]) * 1000 / count).toFixed(2);
  say(`${label} ${name}: ${count} events in ${((Date.now() - started) / 1000).toFixed(1)} s; per event script ${per("ScriptDuration")} ms, task ${per("TaskDuration")} ms, ${(mutations / count).toFixed(1)} DOM mutations; style recalcs ${after.RecalcStyleCount - before.RecalcStyleCount}, layouts ${after.LayoutCount - before.LayoutCount}`);
}

say(`${label} loaded: ${live.length} live agents in ${projects.length} projects; ${JSON.stringify(await settled())}`);

// Sidebar: a label added to agents in every project, at about 20 a second.
await measure("sidebar (agent/changed)", changes, async () => {
  for (let i = 0; i < changes; i++) {
    const agent = live[(i * 37) % live.length];
    await host.call("agents/setLabels", { agentID: agent.id, add: [`${label}${i}`], remove: [] });
    await sleep(50);
  }
});
say(`${label} after sidebar: ${JSON.stringify(await settled())}`);

// Chat: a demo agent in the first project, its chat open while it is prompted.
const folder = projects[0];
const started = await host.call("agents/start", { runtimeID: "demo", cwd: folder, prompt: "hello" });
const agentID = typeof started === "string" ? started : started.id;
const record = async () => (await host.call("agents/list", { agentID, lean: true, limit: 1 })).find((a) => a.id === agentID);
/** Until the turn after `since` has ended. */
const finished = (since = 0) => new Promise((resolve) => {
  const check = async () => {
    const a = await record();
    if (a && a.lastActivityAt > since && a.state !== "running" && a.state !== "starting") resolve(); else setTimeout(check, 20);
  };
  void check();
});
await finished();
const hostID = await page.eval(`document.querySelector('.project-fold[data-folder="${folder}"]').dataset.host`);
await page.eval(`location.hash = "#/" + ["h", ${JSON.stringify(hostID)}, "p", ${JSON.stringify(folder)}, "s", ${JSON.stringify(agentID)}].map(encodeURIComponent).join("/")`);
await page.waitFor(`document.querySelector(".chat .transcript")`, 20_000);
say(`${label} chat opened at ${(await page.eval("location.hash")).slice(0, 60)}`);
const prompt = async (n) => {
  const since = (await record()).lastActivityAt;
  await host.call("agents/prompt", { agentID, text: `Line ${n} with **some** _Markdown_ and \`code\`.`, attachments: [], from: "person" });
  await finished(since);
};
for (let n = 0; n < warmPrompts; n++) await prompt(n);
await sleep(1500);
say(`${label} after ${warmPrompts} prompts in the open chat: ${JSON.stringify(await settled())}`);
await measure("chat (one prompt, its entries and agent/changed)", prompts, async () => {
  for (let n = 0; n < prompts; n++) await prompt(warmPrompts + n);
});
say(`${label} after chat: ${JSON.stringify(await settled())}`);
say(`${label} page errors: ${JSON.stringify(page.errors)}`);
await page.shot(out.replace(/\.txt$/, `-${label || "run"}.png`));
await host.call("agents/archive", { agentID }).catch(() => {});
host.close();
await chrome.close();
