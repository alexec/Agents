// The page's own notification for a notice, and a click on it that opens the chat at the
// notice's line, lit a moment (#2860).
//
//   node Web/test/walk/notify2860.mjs <WEB_URL> <browser code> <out dir> <notify command…>
//
// Headless Chrome shows no notification of its own, so the page gets a stand-in for
// `Notification` that keeps each one made, and the walk clicks it as a person would. It is
// also told it is visible and in front, as the page a person is at. The
// command after the out dir is run once the page is in front, allowed, and on Settings:
// it starts an agent that calls notify. Takes web-settings-ask.png, web-settings-allowed.png,
// web-tapped-lit.png and web-line-sent.png.

import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, ...command] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-2860-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.onNewDocument(`
    window.__notices = [];
    document.hasFocus = () => true;
    Object.defineProperty(document, "visibilityState", { get: () => "visible" });
    window.Notification = class {
      static permission = "default";
      static async requestPermission() { window.Notification.permission = "granted"; return "granted"; }
      constructor(title, options) { this.title = title; this.body = options?.body; this.tag = options?.tag; window.__notices.push(this); }
      close() { this.closed = true; }
    };`);
  await page.goto(webURL);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await sleep(1000);
  await page.eval(`document.getElementById("settings-notifications")?.scrollIntoView({ block: "center" })`);
  await sleep(300);
  await page.shot(`${out}/web-settings-ask.png`);
  await page.press("Allow Notifications");
  await sleep(500);
  await page.shot(`${out}/web-settings-allowed.png`);
  // A person at the page: it says so again now and then, as a focus does, or the host takes
  // it as idle after two minutes and sends the notice to the phone.
  const here = setInterval(() => page.eval(`window.dispatchEvent(new Event("focus"))`).catch(() => {}), 30_000);
  const agent = spawn(command[0], command.slice(1), { stdio: "inherit" });
  try {
    await page.waitFor(`window.__notices.length > 0`, 300_000);
  } finally {
    clearInterval(here);
  }
  await new Promise((done) => (agent.exitCode === null ? agent.once("exit", done) : done()));
  console.log("posted", await page.eval(`JSON.stringify(window.__notices.map((n) => [n.title, n.body, n.tag]))`));
  await page.eval(`window.__notices[0].onclick()`);
  await page.waitFor(`document.querySelector(".notice-line.lit")`, 15_000);
  await sleep(400);
  await page.shot(`${out}/web-tapped-lit.png`);
  console.log("closed", await page.eval(`window.__notices[0].closed === true`));
  await sleep(2500);
  console.log("lines", await page.eval(`JSON.stringify([...document.querySelectorAll(".notice-line")].map((l) => l.innerText.replace(/\\s+/g, " ")))`));
  await page.shot(`${out}/web-line-sent.png`);
} finally {
  await chrome.close();
}
