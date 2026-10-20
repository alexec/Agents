#!/usr/bin/env node
// Private sign-up browser for the sign-up skill: a separate Chrome profile, incognito, driven over
// DevTools. Profiles live in .agents/signups/ (local only, in .git/info/exclude), not beside this file.
// Never Alex's own profile or cookies. Never prints a secret: type-secret reads the Keychain itself.
//
//   node cdp.mjs start                     launch the private Chrome (no-op when it runs)
//   node cdp.mjs open <url>                load a URL in the current tab
//   node cdp.mjs text [max]                print the page's visible text
//   node cdp.mjs eval '<js>'               run JS in the page, print the result
//   node cdp.mjs click '<css or text=…>'   click an element
//   node cdp.mjs type '<css>' '<text>'     set an input's value (fires input/change)
//   node cdp.mjs type-secret '<css>' <service[#account]>  type a Keychain password, never printed
//   node cdp.mjs keys '<css>' <text|kc:service|env:NAME>   real keystrokes, one per character
//   node cdp.mjs mclick '<css or text=…>'  a real mouse click
//   node cdp.mjs shot <file.png>           screenshot
//   node cdp.mjs url                       print the current URL
//   node cdp.mjs stop                      quit the private Chrome
import { execFileSync, spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";

// One sign-up session per provider, each with a browser of its own: CDP_PORT and CDP_PROFILE
// (default 9223 and chrome-profile; e.g. 9224 chrome-profile-digitalocean, 9225 chrome-profile-aws).
const PORT = Number(process.env.CDP_PORT ?? 9223);
const here = dirname(fileURLToPath(import.meta.url));
const profile = join(here, "..", "..", "signups", process.env.CDP_PROFILE ?? "chrome-profile");
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

async function targets() {
  const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  return (await r.json()).filter((t) => t.type === "page");
}

async function up() {
  try { await targets(); return true; } catch { return false; }
}

async function connect() {
  let pages = await targets();
  if (pages.length === 0) {
    await fetch(`http://127.0.0.1:${PORT}/json/new?about:blank`, { method: "PUT" });
    pages = await targets();
  }
  const ws = new WebSocket(pages[0].webSocketDebuggerUrl);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  let id = 0;
  const waiting = new Map();
  const events = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
    else if (msg.method) events.push(msg.method);
  };
  const send = (method, params = {}) => new Promise((ok, bad) => {
    const n = ++id;
    waiting.set(n, (msg) => (msg.error ? bad(new Error(msg.error.message)) : ok(msg.result)));
    ws.send(JSON.stringify({ id: n, method, params }));
  });
  return { send, events, close: () => ws.close() };
}

async function evaluate(c, expression) {
  const r = await c.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

// Finds an element by CSS, or by visible text with "text=…"; looks into open shadow roots too.
const finder = (sel) => `(() => {
  const sel = ${JSON.stringify(sel)};
  const all = (root) => { const out = []; const walk = (n) => { for (const e of n.querySelectorAll('*')) { out.push(e); if (e.shadowRoot) walk(e.shadowRoot); } }; walk(root); return out; };
  if (sel.startsWith('text=')) {
    const want = sel.slice(5).trim().toLowerCase();
    const els = all(document).filter(e => e.offsetParent !== null || e.tagName === 'BODY');
    const clickable = els.filter(e => /^(A|BUTTON|LABEL|INPUT|SPAN|DIV|LI)$/.test(e.tagName));
    return clickable.find(e => (e.innerText || e.value || '').trim().toLowerCase() === want)
        || clickable.find(e => (e.innerText || e.value || '').trim().toLowerCase().includes(want)) || null;
  }
  return document.querySelector(sel) || all(document).find(e => e.matches && e.matches(sel)) || null;
})()`;

async function clickAt(c, sel) {
  const box = await evaluate(c, `(() => { const el = ${finder(sel)}; if (!el) return null; el.scrollIntoView({block:'center'});
    const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  if (!box) return "not found";
  await c.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x - 30, y: box.y - 10 });
  await new Promise((r) => setTimeout(r, 120));
  await c.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x, y: box.y });
  await c.send("Input.dispatchMouseEvent", { type: "mousePressed", x: box.x, y: box.y, button: "left", clickCount: 1 });
  await new Promise((r) => setTimeout(r, 80));
  await c.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: box.x, y: box.y, button: "left", clickCount: 1 });
  return "clicked";
}

const setValue = (sel, valueExpr) => `(() => {
  const el = ${finder(sel)};
  if (!el) return 'not found';
  el.focus();
  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, ${valueExpr});
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return 'ok';
})()`;

// A Keychain item by "service" or "service#account" (two sign-ups can share a service).
const keychain = (item) => {
  const [service, account] = item.split("#");
  const args = ["find-generic-password", "-s", service, ...(account ? ["-a", account] : []), "-w"];
  return execFileSync("security", args, { encoding: "utf8" }).trimEnd();
};

const [cmd, a, b] = process.argv.slice(2);

if (cmd === "start") {
  if (await up()) { console.log("running"); process.exit(0); }
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  spawn(chrome, [
    `--user-data-dir=${profile}`, `--remote-debugging-port=${PORT}`, "--incognito",
    "--no-first-run", "--no-default-browser-check", "--disable-sync", "--window-size=1280,900", "about:blank",
  ], { detached: true, stdio: "ignore" }).unref();
  for (let i = 0; i < 50 && !(await up()); i++) await new Promise((r) => setTimeout(r, 200));
  console.log((await up()) ? "started" : "failed");
  process.exit(0);
}

if (cmd === "stop") {
  const c = await connect();
  await c.send("Browser.close").catch(() => {});
  console.log("stopped");
  process.exit(0);
}

const c = await connect();
try {
  switch (cmd) {
    case "open":
      await c.send("Page.enable");
      await c.send("Page.navigate", { url: a });
      for (let i = 0; i < 100 && !c.events.includes("Page.loadEventFired"); i++) await new Promise((r) => setTimeout(r, 200));
      console.log(await evaluate(c, "location.href"));
      break;
    case "url":
      console.log(await evaluate(c, "location.href + '  |  ' + document.title"));
      break;
    case "text": {
      const t = await evaluate(c, "document.body ? document.body.innerText : ''");
      console.log(t.slice(0, Number(a ?? 6000)));
      break;
    }
    case "eval":
      console.log(JSON.stringify(await evaluate(c, a), null, 1));
      break;
    case "click":
      console.log(await evaluate(c, `(() => { const el = ${finder(a)}; if (!el) return 'not found'; el.scrollIntoView({block:'center'}); el.click(); return 'clicked ' + el.tagName; })()`));
      break;
    case "type":
      console.log(await evaluate(c, setValue(a, JSON.stringify(b))));
      break;
    case "type-secret": {
      const secret = keychain(b);
      console.log(await evaluate(c, setValue(a, JSON.stringify(secret))));
      break;
    }
    case "key": {
      // Types real key events into the focused element (for fields that ignore set values).
      const secret = b ? keychain(b) : null;
      await evaluate(c, `(() => { const el = ${finder(a)}; if (el) el.focus(); })()`);
      await c.send("Input.insertText", { text: secret ?? "" });
      console.log("ok");
      break;
    }
    case "keys": {
      // Types one real key event per character, with human gaps (for forms that fingerprint keystrokes).
      // b is the text, or kc:<service> for a Keychain password, or env:<NAME> for a value in the environment.
      const text = b.startsWith("kc:") ? execFileSync("security", ["find-generic-password", "-s", b.slice(3), "-w"], { encoding: "utf8" }).trimEnd()
        : b.startsWith("env:") ? (process.env[b.slice(4)] ?? "") : b;
      await clickAt(c, a);
      await evaluate(c, `(() => { const el = ${finder(a)}; if (el && 'value' in el) { el.select && el.select(); } })()`);
      for (const ch of text) {
        await c.send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch, unmodifiedText: ch });
        await c.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
        await new Promise((r) => setTimeout(r, 40 + Math.random() * 90));
      }
      console.log("ok");
      break;
    }
    case "mclick":
      // A real mouse click at the element's centre.
      console.log(await clickAt(c, a));
      break;
    case "shot": {
      const r = await c.send("Page.captureScreenshot", { format: "png" });
      writeFileSync(a, Buffer.from(r.data, "base64"));
      console.log(a);
      break;
    }
    default:
      console.error("unknown command; see the header of cdp.mjs");
      process.exitCode = 2;
  }
} finally {
  c.close();
}
