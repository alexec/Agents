// A dependency-free Chrome DevTools client for walking the web remote (071 research R10).
//
//   import { launch } from "./cdp.mjs";
//   const chrome = await launch({ profile: "/tmp/run-x/chrome" });
//   const page = await chrome.page("http://localhost:<port>/", { width: 1440, height: 900 });
//   await page.press("Pair");  await page.shot("walks/a.png");  await chrome.close();
//
// Headless Chrome with a throwaway profile, never the person's own browser. Node's built-in
// WebSocket carries the protocol, so nothing is installed.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

export const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** Starts Chrome on `profile` (made if missing) and connects to it. */
export async function launch({ profile, headed = false, path = chromePath } = {}) {
  if (!profile) throw new Error("say which throwaway profile folder to use");
  mkdirSync(profile, { recursive: true });
  rmSync(`${profile}/DevToolsActivePort`, { force: true });
  const args = [`--user-data-dir=${profile}`, "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check",
    "--disable-background-networking", "--disable-sync", "--hide-scrollbars", "about:blank"];
  if (!headed) args.unshift("--headless=new");
  const child = spawn(path, args, { stdio: "ignore" });
  for (let i = 0; i < 150 && !existsSync(`${profile}/DevToolsActivePort`); i++) await sleep(100);
  const [port, wsPath] = readFileSync(`${profile}/DevToolsActivePort`, "utf8").trim().split("\n");
  const socket = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });

  let next = 1;
  const waiting = new Map();
  const listeners = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && waiting.has(message.id)) {
      const { resolve, reject } = waiting.get(message.id);
      waiting.delete(message.id);
      return message.error ? reject(new Error(`${message.error.message}`)) : resolve(message.result);
    }
    for (const listener of listeners.get(message.sessionId ?? "") ?? []) listener(message);
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = next++;
    waiting.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const exited = new Promise((resolve) => child.on("exit", resolve));

  return {
    send,
    version: async () => (await send("Browser.getVersion")).product,

    /** A new tab on `url`, or in a fresh incognito context with `incognito`. */
    async page(url, { width = 1440, height = 900, incognito = false } = {}) {
      const context = incognito ? (await send("Target.createBrowserContext")).browserContextId : undefined;
      const { targetId } = await send("Target.createTarget", { url: "about:blank", ...(context ? { browserContextId: context } : {}) });
      const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
      const page = makePage(send, sessionId, targetId, (listener) => {
        listeners.set(sessionId, [...(listeners.get(sessionId) ?? []), listener]);
      });
      await page.start(width, height);
      if (url) await page.goto(url);
      return page;
    },

    /** Closes Chrome cleanly, so its profile is written out as a quit would. */
    async close() {
      await send("Browser.close").catch(() => {});
      await Promise.race([exited, sleep(10_000)]);
    },
  };
}

function makePage(send, sessionId, targetId, listen) {
  const console = [];
  const requests = [];
  const errors = [];
  const call = (method, params) => send(method, params, sessionId);

  const page = {
    console, requests, errors, targetId,

    async start(width, height) {
      listen((message) => {
        if (message.method === "Runtime.consoleAPICalled") {
          console.push(message.params.args.map((arg) => arg.value ?? arg.description ?? "").join(" "));
        } else if (message.method === "Network.requestWillBeSent") {
          requests.push(message.params.request.url);
        } else if (message.method === "Runtime.exceptionThrown") {
          errors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
        } else if (message.method === "Log.entryAdded") {
          // CSP violations and other browser complaints arrive here.
          errors.push(`${message.params.entry.source}: ${message.params.entry.text}`);
        }
      });
      await call("Page.enable");
      await call("Runtime.enable");
      await call("Network.enable");
      await call("Log.enable");
      await page.viewport(width, height);
    },

    async viewport(width, height) {
      await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: width < 760 });
    },

    async goto(url) {
      await call("Page.navigate", { url });
      await page.waitFor("document.readyState === 'complete'");
    },

    /** The value of `expression` in the page. CDP is not bound by the page's CSP. */
    async eval(expression) {
      const { result, exceptionDetails } = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
      return result.value;
    },

    async waitFor(expression, timeout = 10_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (await page.eval(`Boolean(${expression})`).catch(() => false)) return;
        await sleep(50);
      }
      throw new Error(`waited ${timeout} ms for ${expression}`);
    },

    /** Clicks the button, link or control whose accessible name is exactly `name`. */
    async press(name) {
      const found = await page.eval(`(() => {
        const wanted = ${JSON.stringify(name)};
        const all = [...document.querySelectorAll("button, a, [role=button], [role=link], [role=tab], [role=menuitem], input, summary")];
        const match = all.find((el) => (el.getAttribute("aria-label") ?? el.textContent ?? "").trim() === wanted);
        if (!match) return false;
        match.click();
        return true;
      })()`);
      if (!found) throw new Error(`nothing to press called ${name}`);
    },

    /** Types `text` into whatever has focus, as a paste would arrive. */
    async type(text) {
      await call("Input.insertText", { text });
    },

    async focus(selector) {
      const found = await page.eval(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); el?.focus(); return !!el; })()`);
      if (!found) throw new Error(`nothing matches ${selector}`);
    },

    async text(selector = "body") {
      return page.eval(`document.querySelector(${JSON.stringify(selector)})?.innerText ?? ""`);
    },

    async shot(path) {
      const { data } = await call("Page.captureScreenshot", { format: "png" });
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, Buffer.from(data, "base64"));
    },
  };
  return page;
}
