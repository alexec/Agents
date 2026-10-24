// The file to see mark and the Finished chats switch on the page (#1802).
//
//   node Web/test/walk/filetosee1802.mjs <WEB_URL> <browser code> <ROOT> <out dir>
//
// The root is a run-app scratch root with a folder `work` and a finished session whose
// agent called show_file on a file nobody has looked at.

import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-f1802-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  await page.eval(`document.querySelector(".row.folder .disclosure")?.click()`);
  await sleep(1500);
  console.log("rows", JSON.stringify(await page.eval(`[...document.querySelectorAll(".row.session")].filter((r) => r.offsetParent !== null).map((r) => r.innerText.replace(/\\s+/g, " ").slice(0, 80))`)));
  const marks = await page.eval(`[...document.querySelectorAll(".file-to-see")].map((m) => m.getAttribute("aria-label"))`);
  console.log("marks", JSON.stringify(marks));
  const needsYou = await page.eval(`[...document.querySelectorAll("details, section")].filter((el) => /^Needs [Yy]ou/.test(el.querySelector("summary, h2")?.textContent ?? "")).map((el) => el.innerText.replace(/\\s+/g, " ").slice(0, 200))`);
  console.log("needs you", JSON.stringify(needsYou));
  console.log("title", await page.eval(`document.title`));
  await page.shot(`${out}/f1802-web-row.png`);
  await page.eval(`location.hash = "#/settings"`);
  await sleep(800);
  const box = await page.eval(`(() => { const label = [...document.querySelectorAll("label.setting")].find((l) => l.textContent.includes("Agents may archive")); return label ? label.querySelector("input").checked : null; })()`);
  console.log("switch on", box);
  await page.shot(`${out}/f1802-web-settings.png`);
  await page.eval(`[...document.querySelectorAll("label.setting")].find((l) => l.textContent.includes("Agents may archive"))?.querySelector("input").click()`);
  await sleep(1500);
  console.log("display.json", readFileSync(`${root}/settings/display.json`, "utf8"));
} finally {
  await chrome.close();
}
