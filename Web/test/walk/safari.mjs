// The closing walk in Safari (071 quickstart §8, T071): §2 pair, §4 read and answer and §6 away
// and back, driven through safaridriver (WebDriver), whose automation window is a session of its
// own, apart from the person's Safari. It needs Safari ▸ Settings ▸ Developer ▸ Allow remote
// automation, and `safaridriver -p 4723` running.
//
//   node Web/test/walk/safari.mjs <WEB_URL> <ROOT> <browser code> <out dir> <rpc.py> <control script>

import { execFileSync, spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const [webURL, root, code, out, rpcPath, control] = process.argv.slice(2);
const driver = "http://127.0.0.1:4723";
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const rpc = (...args) => JSON.parse(execFileSync(rpcPath, [root, "call", ...args], { encoding: "utf8" }));

async function wd(method, path, body) {
  const response = await fetch(driver + path, {
    method, headers: { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await response.json();
  if (json.value?.error) throw new Error(`${path}: ${json.value.error}: ${json.value.message}`);
  return json.value;
}
const { sessionId: id, capabilities } = await wd("POST", "/session", { capabilities: { alwaysMatch: { browserName: "safari" } } });
const s = (path) => `/session/${id}${path}`;
const run = (script, ...args) => wd("POST", s("/execute/sync"), { script, args });
const waitFor = async (expression, timeout = 15_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await run(`return Boolean(${expression})`).catch(() => false)) return;
    await sleep(100);
  }
  throw new Error(`waited ${timeout} ms for ${expression}`);
};
const find = async (css) => Object.values(await wd("POST", s("/element"), { using: "css selector", value: css }))[0];
const shot = async (name) => writeFileSync(`${out}/${name}`, Buffer.from(await wd("GET", s("/screenshot")), "base64"));
const clickText = (selector, text) => run(`const el = [...document.querySelectorAll(arguments[0])]
  .find((e) => e.textContent.trim().startsWith(arguments[1]) && e.offsetParent !== null); el?.click(); return !!el;`, selector, text);

try {
  say(`Safari ${capabilities.browserVersion} on ${capabilities.platformName}`);
  await wd("POST", s("/window/rect"), { width: 1440, height: 900 }).catch(() => {});

  // §2. Pair, with the key Safari keeps and can't give out.
  await wd("POST", s("/url"), { url: webURL });
  await waitFor(`document.querySelector("textarea")`);
  say(`secure context: ${await run("return window.isSecureContext")}; title: ${JSON.stringify(await run("return document.title"))}`);
  const box = await find("textarea");
  await wd("POST", s(`/element/${box}/value`), { text: code });
  await clickText("button", "Connect");
  await waitFor(`document.querySelector(".projects .row")`, 30_000);
  say(`§2 paired: ${JSON.stringify(await run(`return document.querySelector(".identity span")?.textContent`))}`);
  await shot("safari-1-paired.png");
  // Connecting again with the stored key: a reload, nothing pasted.
  await wd("POST", s("/refresh"), {});
  await waitFor(`document.querySelector(".projects .row")`, 30_000);
  say("after a reload: connected again with the stored key, nothing pasted");

  // §4. Read and answer: a real Claude turn, started on the host's socket, answered in Safari.
  await clickText(".projects .row", "work");
  await waitFor(`document.querySelector(".sessions .section-head")`);
  const prompt = "This is a test of answering from Safari. Do exactly these steps, in order, and nothing else: "
    + "1. Use your AskUserQuestion tool to ask me which greeting to write, with the options Hello and Howdy. "
    + "2. Run this with your Bash tool: echo <the greeting I chose> > safari.txt "
    + "3. Say in one sentence what you did.";
  const turn = spawn(rpcPath, [root, "start", "claude", `${root}/work`, prompt, "300", "--ask"], { stdio: ["ignore", "pipe", "pipe"] });
  let agentID = null;
  turn.stdout.on("data", (chunk) => { const m = /agentID: "([0-9A-F-]{36})"/.exec(String(chunk)); if (m) agentID = m[1]; });
  while (!agentID) await sleep(200);
  say(`started ${agentID} on the host's socket`);
  await run(`location.hash = "#/h/mac/p/" + encodeURIComponent("file://${root}/work") + "/s/${agentID}"`);
  await waitFor(`document.querySelector(".card[aria-label=Question]")`, 180_000);
  await shot("safari-2-question.png");
  await clickText(".card[aria-label=Question] button", "Howdy");
  await sleep(300);
  await clickText(".card[aria-label=Question] button", "Submit");
  await waitFor(`!document.querySelector(".card[aria-label=Question]")`, 30_000);
  say("answered the question in Safari: Howdy");
  await waitFor(`document.querySelector(".card[aria-label='Permission request']")`, 180_000);
  say(`permission card: ${JSON.stringify(await run(`return document.querySelector(".card[aria-label='Permission request'] .strong")?.textContent`))}`);
  await run(`[...document.querySelectorAll(".card[aria-label='Permission request'] button")].find((b) => b.classList.contains("prominent"))?.click()`);
  say("allowed it in Safari");
  let agent = null;
  for (let i = 0; i < 240; i++) {
    agent = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => a.id === agentID);
    if (agent && !["running", "starting", "waitingOnUser"].includes(agent.state)) break;
    await sleep(500);
  }
  say(`the turn ended: ${agent.state}${agent.report ? `, ${agent.report.outcome}: ${agent.report.message}` : ""}`);
  await sleep(1500);
  say(`the chat says: ${JSON.stringify((await run(`return document.querySelector(".transcript")?.innerText ?? ""`)).slice(-240))}`);
  await shot("safari-3-answered.png");
  turn.kill();

  // §6. Away and back: the control plane stopped for 15 s and started again, with no reload.
  await run("window.__notReloaded = true");
  execFileSync(control, ["stop"], { stdio: "pipe" });
  const away = Date.now();
  await waitFor(`document.querySelector(".banner")?.textContent.includes("Can't reach the control plane")`, 15_000);
  say(`away: the banner came after ${((Date.now() - away) / 1000).toFixed(1)} s`);
  await shot("safari-4-away.png");
  await sleep(15_000);
  execFileSync(control, ["start"], { stdio: "pipe" });
  const back = Date.now();
  await waitFor(`!document.querySelector(".banner")`, 30_000);
  say(`back: the banner went ${((Date.now() - back) / 1000).toFixed(1)} s after the control plane started; not reloaded: ${await run("return window.__notReloaded === true")}`);
  await shot("safari-5-back.png");
} finally {
  writeFileSync(`${out}/safari-notes.txt`, notes.join("\n") + "\n");
  await wd("DELETE", `/session/${id}`).catch(() => {});
}
