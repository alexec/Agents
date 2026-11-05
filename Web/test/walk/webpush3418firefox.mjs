// Web Push in a real Firefox, through Mozilla's push service (#3418).
//
//   node Web/test/walk/webpush3418firefox.mjs <firefox binary> <WEB_URL> <browser code> <out dir> [subscribe|wait]
//
// Firefox on a throwaway profile whose prefs allow notifications, driven over WebDriver BiDi
// with Node's own WebSocket, so nothing is installed. Headless, unless DISPLAY is set: a
// headless Firefox on Linux shows no notification, so `wait` runs under xvfb-run, with
// Firefox's own alert windows. It pairs with the code and waits for the page to subscribe.
// With `wait` it then leaves the page for a plain file on the same origin, as a person who
// went away, and waits up to ten minutes for one push, read from the service worker's shown
// notifications. Writes subscription.json (the endpoint's host only), firefox.log (its push
// log) and, with wait, pushed.json.
//
// This Mac's Firefox cannot start from an agent's session, so the walk runs in a container
// with Firefox ESR, the page's port forwarded to localhost (a secure origin) in it.

import { spawn } from "node:child_process";
import { mkdirSync, openSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";

const [firefox, webURL, code, out, mode = "subscribe"] = process.argv.slice(2);
const profile = `${out}/firefox`;
mkdirSync(profile, { recursive: true });
writeFileSync(`${profile}/user.js`, [
  `user_pref("permissions.default.desktop-notification", 1);`,
  `user_pref("browser.shell.checkDefaultBrowser", false);`,
  `user_pref("datareporting.policy.dataSubmissionEnabled", false);`,
  `user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);`,
  // WebDriver BiDi's recommended prefs turn the push connection off.
  `user_pref("remote.prefs.recommended", false);`,
  `user_pref("dom.push.connection.enabled", true);`,
  `user_pref("dom.push.loglevel", "debug");`,
  `user_pref("devtools.console.stdout.chrome", true);`,
  // Firefox's own alert windows, not the desktop's: a container has no notification daemon.
  `user_pref("alerts.useSystemBackend", false);`,
].join("\n"));

const port = await new Promise((resolve) => {
  const server = createServer().listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
});
const logFile = openSync(`${out}/firefox.log`, "w");
const child = spawn(firefox, [...(process.env.DISPLAY ? [] : ["--headless"]), "--no-remote", "--profile", profile,
  `--remote-debugging-port=${port}`, "about:blank"], { stdio: ["ignore", logFile, logFile] });
const end = () => { if (child.exitCode === null) child.kill(); };
process.on("exit", end);

let socket;
for (let i = 0; i < 100 && !socket; i++) {
  await sleep(200);
  socket = await new Promise((resolve) => {
    const s = new WebSocket(`ws://127.0.0.1:${port}/session`);
    s.onopen = () => resolve(s);
    s.onerror = () => resolve(undefined);
  });
}
if (!socket) throw new Error("Firefox did not open WebDriver BiDi");
let next = 1;
const waiting = new Map();
socket.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.method === "log.entryAdded") console.log("console:", message.params.text);
  const pending = waiting.get(message.id);
  if (!pending) return;
  waiting.delete(message.id);
  if (message.type === "error") pending.reject(new Error(`${message.error}: ${message.message}`));
  else pending.resolve(message.result);
};
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = next++;
  waiting.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params }));
});

try {
  await send("session.new", { capabilities: {} });
  await send("session.subscribe", { events: ["log.entryAdded"] });
  const { contexts } = await send("browsingContext.getTree", {});
  const context = contexts[0].context;
  const run = async (expression) => {
    const { result, exceptionDetails } = await send("script.evaluate", { expression, target: { context }, awaitPromise: true, resultOwnership: "none" });
    if (exceptionDetails) throw new Error(exceptionDetails.text);
    return result.value;
  };
  const waitFor = async (expression, timeout = 20_000) => {
    for (const start = Date.now(); Date.now() - start < timeout; await sleep(250)) {
      if (await run(`Boolean(${expression})`).catch(() => false)) return;
    }
    throw new Error(`waited ${timeout} ms for ${expression}`);
  };
  await send("browsingContext.navigate", { context, url: webURL, wait: "complete" });
  await waitFor(`document.querySelector("textarea")`);
  await run(`(() => {
    const field = document.querySelector("textarea");
    field.value = ${JSON.stringify(code)};
    field.dispatchEvent(new Event("input", { bubbles: true }));
  })()`);
  await sleep(200);
  await run(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "Connect").click()`);
  await waitFor(`document.querySelector(".top-bar")`, 30_000).catch(async (error) => {
    console.log((await run(`document.body.innerText`)).slice(0, 300));
    throw error;
  });
  const subscribed = `navigator.serviceWorker.getRegistration("/").then((r) => r?.pushManager.getSubscription()).then((s) => s?.endpoint ?? "")`;
  let endpoint = "";
  for (let i = 0; i < 60 && !endpoint; i++) {
    endpoint = await run(subscribed).catch(() => "");
    if (!endpoint) await sleep(500);
  }
  const host = endpoint ? new URL(endpoint).host : "";
  console.log("subscribed", host || "no subscription", "permission", await run(`Notification.permission`));
  writeFileSync(`${out}/subscription.json`, JSON.stringify({ host }));
  if (!endpoint || mode !== "wait") process.exit(endpoint ? 0 : 1);

  // A plain file on the same origin: the page is gone, its service worker stays.
  await send("browsingContext.navigate", { context, url: new URL("/app.css", webURL).href, wait: "complete" });
  console.log("waiting for a push");
  for (let i = 0; i < 600; i++) {
    const shown = JSON.parse(await run(`navigator.serviceWorker.getRegistration("/")
      .then((r) => r ? r.getNotifications() : [])
      .then((n) => JSON.stringify(n.map((x) => ({ title: x.title, body: x.body, tag: x.tag }))))`));
    if (shown.length) {
      console.log("pushed", shown);
      writeFileSync(`${out}/pushed.json`, JSON.stringify(shown));
      process.exit(0);
    }
    await sleep(1000);
  }
  throw new Error("no push in ten minutes");
} finally {
  await send("browser.close", {}).catch(() => {});
  end();
}
