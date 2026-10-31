// The #1810 walk: Settings ▸ Backups on the page. Pairs, opens Settings, shoots the section, presses
// Back Up Now and Restore… (confirmed), and shoots what it says.
//
//   node Web/test/walk/backups1810.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/1810-backups-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`!!document.getElementById("settings-backups")`, 20_000);
  await page.eval(`document.getElementById("settings-backups").scrollIntoView()`);
  await sleep(500);
  await page.shot(`${out}/web-backups.png`);
  const before = await page.eval(`document.querySelectorAll("#settings-backups ~ .setting button").length`);
  await page.eval(`window.confirm = () => true`);
  await page.press("Back Up Now");
  await sleep(2500);
  await page.press("Restore…");
  await page.waitFor(`document.querySelector(".settings-body").innerText.includes("here already")`, 10_000);
  await page.eval(`document.getElementById("settings-backups").scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-backups-restored.png`);
  console.log("said:", await page.eval(`[...document.querySelectorAll("section[aria-labelledby=settings-backups] .hint")].map((p) => p.innerText)[0]`), "buttons before:", before);
} finally {
  await chrome.close();
}
