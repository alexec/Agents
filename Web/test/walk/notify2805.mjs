// What an agent told the person with notify, and Settings ▸ Notifications, on the page (#2805).
//
//   node Web/test/walk/notify2805.mjs <WEB_URL> <browser code> <ROOT> <out dir> <session title>…
//
// The root is a run-app scratch root with a folder `work` and finished sessions whose agents
// called notify. Takes web-<n>.png of each session named, then web-settings.png, sets
// Cool-down to 10 minutes there, and prints the host's display.json.

import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out, ...titles] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-notify-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  await page.eval(`document.querySelector(".row.folder .disclosure")?.click()`);
  await sleep(1500);
  for (const [i, title] of titles.entries()) {
    await page.eval(`[...document.querySelectorAll(".row.session")].find((r) => r.innerText.includes(${JSON.stringify(title)}))?.click()`);
    await sleep(2000);
    const lines = await page.eval(`[...document.querySelectorAll(".notice-line")].map((l) => l.innerText.replace(/\\s+/g, " "))`);
    console.log(title, JSON.stringify(lines));
    await page.shot(`${out}/web-chat-${i + 1}.png`);
  }
  await page.eval(`location.hash = "#/settings"`);
  await sleep(800);
  await page.eval(`document.getElementById("settings-notifications")?.scrollIntoView({ block: "center" })`);
  await sleep(300);
  const input = `[...document.querySelectorAll("label.setting")].find((l) => l.textContent.includes("Cool-down"))?.querySelector("input")`;
  console.log("cool-down shown", await page.eval(`${input}?.value`));
  await page.eval(`(() => { const i = ${input}; i.value = "10"; i.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await sleep(1500);
  await page.shot(`${out}/web-settings.png`);
  console.log("display.json", readFileSync(`${root}/settings/display.json`, "utf8"));
} finally {
  await chrome.close();
}
