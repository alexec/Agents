// Runs the S1 spike page in Chrome over the DevTools protocol (071 T001, research R1).
//
//   node run-chrome.mjs [--headed] [port]      # serve.py must be serving on <port> (8893)
//
// For each origin (localhost and 127.0.0.1) it uses a fresh throwaway profile under
// /tmp/s1-chrome: run the page, close Chrome cleanly, launch it again on the same profile,
// run again (the key must be the one made before), then once more in an incognito
// context. Results go to stdout as JSON. Nothing touches the person's own Chrome profile.

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const headed = process.argv.includes("--headed");
const port = Number(process.argv.find((a) => /^\d+$/.test(a)) ?? 8893);

async function launch(profile) {
  rmSync(`${profile}/DevToolsActivePort`, { force: true });
  const args = [`--user-data-dir=${profile}`, "--remote-debugging-port=0", "--no-first-run",
                "--no-default-browser-check", "--disable-background-networking", "--disable-sync",
                "about:blank"];
  if (!headed) args.unshift("--headless=new");
  const child = spawn(CHROME, args, { stdio: "ignore" });
  for (let i = 0; i < 100 && !existsSync(`${profile}/DevToolsActivePort`); i++) await sleep(100);
  const [devPort, path] = readFileSync(`${profile}/DevToolsActivePort`, "utf8").trim().split("\n");
  const ws = new WebSocket(`ws://127.0.0.1:${devPort}${path}`);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let next = 1;
  const waiting = new Map();
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && waiting.has(message.id)) {
      const { resolve, reject } = waiting.get(message.id);
      waiting.delete(message.id);
      message.error ? reject(new Error(message.error.message)) : resolve(message.result);
    }
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = next++;
    waiting.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const exited = new Promise((resolve) => child.on("exit", resolve));
  return { send, ws, exited };
}

async function runPage(browser, url, browserContextId) {
  const { targetId } = await browser.send("Target.createTarget", { url: "about:blank", ...(browserContextId ? { browserContextId } : {}) });
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
  await browser.send("Page.enable", {}, sessionId);
  await browser.send("Page.navigate", { url }, sessionId);
  for (let i = 0; i < 100; i++) {
    await sleep(100);
    const { result } = await browser.send("Runtime.evaluate", { expression: "document.title", returnByValue: true }, sessionId);
    if (result.value === "done" || result.value === "failed") break;
  }
  const { result } = await browser.send("Runtime.evaluate",
    { expression: "JSON.stringify(window.spikeResult ?? null)", returnByValue: true }, sessionId);
  await browser.send("Target.closeTarget", { targetId });
  return JSON.parse(result.value);
}

async function close(browser) {
  await browser.send("Browser.close").catch(() => {});
  await Promise.race([browser.exited, sleep(10_000)]);
}

const report = { headed, chrome: null, runs: {} };
for (const host of ["localhost", "127.0.0.1"]) {
  const url = `http://${host}:${port}/`;
  const profile = `/tmp/s1-chrome/${headed ? "headed" : "headless"}-${host}`;
  rmSync(profile, { recursive: true, force: true });
  mkdirSync(profile, { recursive: true });

  let browser = await launch(profile);
  report.chrome ??= (await browser.send("Browser.getVersion")).product;
  const first = await runPage(browser, url);
  await close(browser);

  browser = await launch(profile);
  const afterRestart = await runPage(browser, url);
  const { browserContextId } = await browser.send("Target.createBrowserContext");
  const incognito = await runPage(browser, url, browserContextId);
  await close(browser);

  report.runs[host] = { first, afterRestart, incognito };
}
console.log(JSON.stringify(report, null, 2));
