// Drives a Chrome for make.py, one JSON command a line on stdin, one JSON answer a line on
// stdout: the web page in headless Chrome, or for an integration scene (#1794) an outside site
// in the video profile, a real Chrome signed in once by the person. It records the tab in
// front with the DevTools screencast: each frame is a JPEG in <dir>/frames, <dir>/frames.json
// has each frame's unix time, and <dir>/secrets.json the places on it that show a secret.
//
//   node web.mjs <profile folder> ['{"headed":true}']
//
// Commands: {op:"open", url, width, height, mobile, scheme, tab}, {op:"tab", name},
// {op:"pair", code}, {op:"record", dir}, {op:"stop"}, {op:"press", name},
// {op:"click", text, within}, {op:"type", selector, text}, {op:"key", key, modifiers},
// {op:"secret", selector or pattern}, {op:"url"}, {op:"waitUrl", prefix, timeout}, {op:"forget", origin},
// {op:"waitFor", expr, timeout}, {op:"eval", expr}, {op:"shot", path}, {op:"close"}.
//
// A secret (a DOM selector, or a pattern that an element's text or value holds) is blurred by
// the page itself, in every tab and every page it loads, before a frame is drawn; its places
// are also written for frame.py to blur again.
import { mkdirSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "../../Web/test/walk/cdp.mjs";

const options = JSON.parse(process.argv[3] ?? "{}");
const chrome = await launch({ profile: process.argv[2], headed: !!options.headed,
  // A tab behind others still draws, so its screencast does not stop.
  args: ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", "--disable-background-timer-throttling"] });
// Headless Chrome names itself HeadlessChrome; a site that sees that can refuse the page.
const agent = (await chrome.send("Browser.getVersion")).userAgent.replace("HeadlessChrome", "Chrome");
const tabs = new Map();
let page;
let recording;
const secrets = [];
const patterns = [];
const visited = [];

const blurring = (selector) => `(() => {
  const add = () => {
    const style = document.createElement("style");
    style.textContent = ${JSON.stringify(`${selector} { filter: blur(14px) !important; }`)};
    (document.head ?? document.documentElement).appendChild(style);
  };
  if (document.documentElement) add(); else document.addEventListener("DOMContentLoaded", add);
})()`;

// An element whose text or value holds the pattern gets data-agents-secret, as soon as it
// is in the page (a MutationObserver runs before the next paint), and that is blurred.
const marking = (pattern) => `(() => {
  const re = new RegExp(${JSON.stringify(pattern)});
  const mark = (el) => { if (el?.setAttribute && !el.hasAttribute("data-agents-secret")) el.setAttribute("data-agents-secret", ""); };
  const look = () => {
    for (const el of document.querySelectorAll("input, textarea")) if (re.test(el.value ?? "")) mark(el);
    const walker = document.createTreeWalker(document.body ?? document.documentElement, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) if (re.test(node.nodeValue)) mark(node.parentElement);
  };
  const start = () => {
    look();
    new MutationObserver(look).observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true });
    document.addEventListener("input", look, true);
  };
  if (document.documentElement) start(); else document.addEventListener("DOMContentLoaded", start);
})()`;

// Each secret's boxes on the tab, as parts of the view (0…1), for frame.py.
const places = () => page.eval(`(() => {
  const w = innerWidth, h = innerHeight, out = [];
  for (const selector of ${JSON.stringify(secrets)}) {
    for (const el of document.querySelectorAll(selector)) {
      const r = el.getBoundingClientRect();
      if (r.width && r.height) out.push([r.x / w, r.y / h, r.width / w, r.height / h]);
    }
  }
  return out;
})()`).catch(() => [[0, 0, 1, 1]]);  // a page that cannot say where its secrets are is blurred whole

async function newTab(name, { width, height, mobile, scheme }) {
  const tab = await chrome.page(undefined, { width, height });
  await tab.cdp("Network.setUserAgentOverride", { userAgent: agent });
  await tab.cdp("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
  await tab.cdp("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: mobile ? 3 : 2, mobile });
  if (mobile) await tab.cdp("Emulation.setTouchEmulationEnabled", { enabled: true });
  for (const pattern of patterns) await tab.onNewDocument(marking(pattern));
  for (const selector of secrets) await tab.onNewDocument(blurring(selector));
  tab.onEvent("Page.frameNavigated", ({ frame }) => { if (!frame.parentId) visited.push(frame.url); });
  tab.onEvent("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
    const r = recording;
    if (!r || page !== tab) return void tab.cdp("Page.screencastFrameAck", { sessionId }).catch(() => {});
    const at = r.times.length;
    r.times.push(metadata.timestamp);
    r.places.push(secrets.length ? await places() : []);
    writeFileSync(`${r.dir}/frames/${String(at).padStart(6, "0")}.jpg`, Buffer.from(data, "base64"));
    await tab.cdp("Page.screencastFrameAck", { sessionId }).catch(() => {});
  });
  tabs.set(name, tab);
  return tab;
}

const ops = {
  async open({ url, width, height, mobile = false, scheme = "light", tab = "main" }) {
    const known = tabs.get(tab);
    const opened = known ?? await newTab(tab, { width, height, mobile, scheme });
    await ops.tab({ name: tab, made: opened });
    await page.goto(url);
  },
  /** The tab in front, the one recorded. */
  async tab({ name }) {
    const next = tabs.get(name);
    if (!next) throw new Error(`no tab called ${name}`);
    if (next === page) return;
    if (recording && page) await page.cdp("Page.stopScreencast").catch(() => {});
    page = next;
    await chrome.send("Target.activateTarget", { targetId: page.targetId }).catch(() => {});
    if (recording) await page.cdp("Page.startScreencast", { format: "jpeg", quality: 92, everyNthFrame: 1 });
  },
  async pair({ code }) {
    await page.waitFor(`document.querySelector("textarea")`);
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
    await page.waitFor(`document.querySelector(".row .title")`, 30_000);
  },
  async record({ dir }) {
    mkdirSync(`${dir}/frames`, { recursive: true });
    recording = { dir, times: [], places: [] };
    await page.cdp("Page.startScreencast", { format: "jpeg", quality: 92, everyNthFrame: 1 });
  },
  async stop() {
    await page.cdp("Page.stopScreencast");
    await sleep(300);
    writeFileSync(`${recording.dir}/frames.json`, JSON.stringify(recording.times));
    writeFileSync(`${recording.dir}/secrets.json`, JSON.stringify(recording.places));
    const frames = recording.times.length;
    recording = undefined;
    return frames;
  },
  /** From now on, what `selector` matches is blurred in every tab, before it is drawn. */
  async secret({ selector, pattern }) {
    if (pattern) {
      patterns.push(pattern);
      for (const tab of tabs.values()) {
        await tab.onNewDocument(marking(pattern));
        await tab.eval(marking(pattern)).catch(() => {});
      }
      if (secrets.includes("[data-agents-secret]")) return;
      selector = "[data-agents-secret]";
    }
    secrets.push(selector);
    for (const tab of tabs.values()) {
      await tab.onNewDocument(blurring(selector));
      await tab.eval(blurring(selector)).catch(() => {});
    }
  },
  async url() { return page.eval("location.href"); },
  /** The first address the tab went to that starts with `prefix`: a hand-back page's, say. */
  async waitUrl({ prefix, timeout = 120_000 }) {
    const deadline = Date.now() + timeout;
    for (;;) {
      const hit = visited.find((u) => u.startsWith(prefix));
      if (hit) return hit;
      if (Date.now() > deadline) throw new Error(`no page at ${prefix} in ${timeout} ms`);
      await sleep(200);
    }
  },
  /** Forgets what a page kept in this profile: a scratch page's pairing, say. */
  async forget({ origin }) {
    await chrome.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  },
  async press({ name }) { await page.press(name); },
  /** Clicks the innermost visible control whose text holds `text`, inside `within` if given, once there is one. */
  async click({ text, within = "body", timeout = 20_000 }) {
    const deadline = Date.now() + timeout;
    for (;;) {
      if (await ops.tryClick({ text, within })) return;
      if (Date.now() > deadline) throw new Error(`nothing to click holds ${text}`);
      await sleep(250);
    }
  },
  async tryClick({ text, within }) {
    return page.eval(`(() => {
      const root = document.querySelector(${JSON.stringify(within)}) ?? document.body;
      const all = [...root.querySelectorAll("button, a, [role=button], [role=menuitem], [role=option], .row, li, summary, label")]
        .filter((e) => e.offsetParent !== null && e.textContent.includes(${JSON.stringify(text)}));
      const hit = all.at(-1);
      hit?.scrollIntoView({ block: "center" });
      hit?.click();
      return !!hit;
    })()`);
  },
  async type({ selector, text, delay = 45 }) {
    if (selector) await page.focus(selector);
    for (const character of text) { await page.type(character); await sleep(delay); }
  },
  async key({ key, code, modifiers = 0 }) { await page.key(key, { code: code ?? key, modifiers }); },
  async waitFor({ expr, timeout = 30_000 }) { await page.waitFor(expr, timeout); },
  async eval({ expr }) { return page.eval(expr); },
  async shot({ path }) { await page.shot(path); },
  async close() { await chrome.close(); setTimeout(() => process.exit(0), 100); },
};

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue;
  const command = JSON.parse(line);
  try {
    const value = await ops[command.op](command);
    process.stdout.write(JSON.stringify({ ok: true, value: value ?? null }) + "\n");
  } catch (error) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(error.message ?? error) }) + "\n");
  }
}
