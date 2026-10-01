// The US7 walk (071 quickstart §6, T062): the control plane stopped mid-turn for 60 s and started
// again, then the host frozen and thawed, timed from headless Chrome on a scratch root.
//
//   node Web/test/walk/us7.mjs <WEB_URL> <ROOT> <device code> <out dir> <control script> <rpc.py>
//
// `control script` takes stop, start, freeze and thaw. The turn is started and its permissions
// answered on the host's own socket (rpc.py), which doesn't go through the control plane, so the
// agent works on while the control plane is away.

import { execFileSync, spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, root, deviceCode, out, control, rpcPath] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const rpc = (...args) => JSON.parse(execFileSync(rpcPath, [root, "call", ...args], { encoding: "utf8" }));
const hands = (verb) => execFileSync(control, [verb], { stdio: "pipe" });
const seconds = (from) => ((Date.now() - from) / 1000).toFixed(1);

const chrome = await launch({ profile: `/tmp/071-us7-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(deviceCode);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

// A turn of several commands, each allowed on the host's socket as it is asked.
const prompt = "Run each of these with your Bash tool, one call at a time, and after each say in one line what it printed: "
  + "`date`, `uname -s`, `whoami`, `pwd`, `ls -a`, `date`, `echo done`. Then say in one sentence what you did.";
const turn = spawn(rpcPath, [root, "start", "claude", `${root}/work`, prompt, "240"], { stdio: ["ignore", "pipe", "pipe"] });
let agentID = null;
turn.stdout.on("data", (chunk) => {
  const found = /agentID: "([0-9A-F-]{36})"/.exec(String(chunk));
  if (found) agentID = found[1];
});
while (!agentID) await sleep(200);
say(`started ${agentID} on the host's socket`);

await page.eval(`(() => { const row = [...document.querySelectorAll(".projects .row")].find((r) => r.textContent.startsWith("work")); row?.click(); })()`);
await page.waitFor(`document.querySelector(".group[aria-label=Working] .session")`, 60_000);
await page.eval(`document.querySelector(".group[aria-label=Working] .session").click()`);
await page.waitFor(`document.querySelector(".chat .transcript")?.textContent.length > 0`, 30_000);
// Mid-turn: the first command has been asked for.
for (;;) {
  const transcript = rpc("agents/transcript", JSON.stringify({ agentID, limit: 400 }));
  if (transcript.entries.some((e) => e.kind.toolCall)) break;
  await sleep(500);
}
await page.focus(".chat textarea[aria-label=Prompt]");
await page.type("A draft typed before it went away.");
await page.shot(`${out}/us7-1-before.png`);
// Gone on a reload: catching up must not need one.
await page.eval("window.__notReloaded = true");

// 1. The control plane stops.
const stoppedAt = Date.now();
hands("stop");
await page.waitFor(`document.querySelector(".banner")?.textContent.includes("Can't reach the control plane")`, 15_000);
say(`stopped: the banner in ${seconds(stoppedAt)} s`);
const greyed = await page.eval(`({
  greyed: getComputedStyle(document.querySelector(".columns")).opacity,
  sendable: !document.querySelector(".chat button.send")?.disabled,
  draft: document.querySelector(".chat textarea[aria-label=Prompt]")?.value,
  rows: document.querySelectorAll(".sessions .session").length,
  chat: document.querySelector(".chat .transcript")?.textContent.length,
})`);
say(`while down: ${JSON.stringify(greyed)}`);
await page.focus(".chat textarea[aria-label=Prompt]");
await page.type(" And more typed while it was away.");
await page.shot(`${out}/us7-2-down.png`);
// The rest of the minute away, while the agent works on.
await sleep(60_000 - (Date.now() - stoppedAt));
const during = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => a.id === agentID);
const entriesNow = rpc("agents/transcript", JSON.stringify({ agentID, limit: 400 })).total;
say(`after ${seconds(stoppedAt)} s away: the agent is ${during.state}, with ${entriesNow} entries on the host`);

// 2. It comes back.
const startedAt = Date.now();
hands("start");
await page.waitFor(`!document.querySelector(".banner")`, 30_000);
const reconnected = seconds(startedAt);
// Caught up: the page holds what the host holds, entry for entry.
const report = during.report?.message;
await page.waitFor(`(() => { const t = document.querySelector(".chat .transcript")?.textContent ?? "";
  return ${JSON.stringify(during.state)} === "running" || ${JSON.stringify(report ?? "")} === "" || t.includes(${JSON.stringify((report ?? "").slice(0, 40))}); })()`, 30_000);
say(`back: reconnected in ${reconnected} s, caught up in ${seconds(startedAt)} s`);
const after = await page.eval(`({
  greyed: getComputedStyle(document.querySelector(".columns")).opacity,
  draft: document.querySelector(".chat textarea[aria-label=Prompt]")?.value,
  sendable: !document.querySelector(".chat button.send")?.disabled,
  notReloaded: window.__notReloaded === true,
})`);
say(`after: ${JSON.stringify(after)}`);
await page.shot(`${out}/us7-3-back.png`);

// Let the turn end, then hold the page to the host's record.
for (let i = 0; i < 240; i++) {
  const agent = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => a.id === agentID);
  if (agent.state !== "running" && agent.state !== "starting" && agent.state !== "waitingOnUser") {
    say(`turn ended: ${agent.state}${agent.report ? `, ${agent.report.outcome}: ${agent.report.message}` : ""}`);
    await page.waitFor(`document.querySelector(".chat .transcript")?.textContent.includes(${JSON.stringify((agent.report?.message ?? "").slice(0, 40))})`, 15_000);
    break;
  }
  await sleep(1000);
}
const pageText = await page.text(".chat .transcript");
const hostTranscript = rpc("agents/transcript", JSON.stringify({ agentID, limit: 400 })).entries;
const said = hostTranscript.filter((e) => e.kind.agentMessage).map((e) => e.kind.agentMessage.text).join("");
const lastWords = said.trim().split(/\s+/).slice(-6).join(" ");
say(`the page ends with the host's last words ("${lastWords}"): ${pageText.replace(/\s+/g, " ").includes(lastWords.replace(/[`*_]/g, ""))}`);
await page.shot(`${out}/us7-4-done.png`);

// 3. The host goes offline; the control plane stays.
const frozenAt = Date.now();
hands("freeze");
try {
  await page.waitFor(`document.querySelector(".host-offline")`, 120_000);
  say(`host frozen: shown offline in ${seconds(frozenAt)} s: ${JSON.stringify(await page.text(".host-offline .row.offline"))}`);
  say(`chat strip: ${JSON.stringify(await page.eval(`document.querySelector(".offline-strip")?.textContent ?? null`))}; sendable: ${await page.eval(`!document.querySelector(".chat button.send")?.disabled`)}; banner: ${await page.eval(`!!document.querySelector(".banner")`)}`);
  await page.shot(`${out}/us7-5-host-offline.png`);
} finally {
  const thawedAt = Date.now();
  hands("thaw");
  await page.waitFor(`!document.querySelector(".host-offline")`, 60_000);
  say(`host thawed: online again in ${seconds(thawedAt)} s`);
}
say(`page errors: ${JSON.stringify(page.errors)}`);
writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
turn.kill();
await chrome.close();
