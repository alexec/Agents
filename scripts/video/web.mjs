// Drives the web page in headless Chrome for make.py, one JSON command a line on stdin, one
// JSON answer a line on stdout. It records the page with the DevTools screencast: each frame
// is a JPEG in <dir>/frames, and <dir>/frames.json has each frame's unix time.
//
//   node web.mjs <profile folder>
//
// Commands: {op:"open", url, width, height, mobile, scheme}, {op:"pair", code}, {op:"record", dir},
// {op:"stop"}, {op:"press", name}, {op:"click", text, within}, {op:"type", selector, text},
// {op:"waitFor", expr, timeout}, {op:"eval", expr}, {op:"shot", path}, {op:"close"}.
import { mkdirSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "../../Web/test/walk/cdp.mjs";

const chrome = await launch({ profile: process.argv[2] });
let page;
let recording;

const ops = {
  async open({ url, width, height, mobile = false, scheme = "light" }) {
    page = await chrome.page(url, { width, height });
    await page.cdp("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
    if (mobile) {
      await page.cdp("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 3, mobile: true });
      await page.cdp("Emulation.setTouchEmulationEnabled", { enabled: true });
    } else {
      await page.cdp("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false });
    }
    await page.goto(url);
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
    recording = { dir, times: [] };
    const r = recording;
    page.onEvent("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
      if (recording !== r) return;
      writeFileSync(`${dir}/frames/${String(r.times.length).padStart(6, "0")}.jpg`, Buffer.from(data, "base64"));
      r.times.push(metadata.timestamp);
      await page.cdp("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });
    await page.cdp("Page.startScreencast", { format: "jpeg", quality: 92, everyNthFrame: 1 });
  },
  async stop() {
    await page.cdp("Page.stopScreencast");
    await sleep(300);
    writeFileSync(`${recording.dir}/frames.json`, JSON.stringify(recording.times));
    const frames = recording.times.length;
    recording = undefined;
    return frames;
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
      const all = [...root.querySelectorAll("button, a, [role=button], .row, li, summary, label")]
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
