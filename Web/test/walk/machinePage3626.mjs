// The #3626 walk: Machines ▸ <machine> on the page. Pairs, opens Machines, shoots each machine's page, then
// presses Settings… and checks the page went to Settings.
//
//   node Web/test/walk/machinePage3626.mjs <WEB_URL> <browser code> <out dir> <profile>
//
// It waits after pairing until <out dir>/go-on exists.

import { existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, profile] = process.argv.slice(2);
const chrome = await launch({ profile });

try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  // Until the window has approved this browser into the lock.
  while (!existsSync(`${out}/go-on`)) await sleep(1000);
  await page.eval(`location.reload()`);
  await sleep(1000);
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelectorAll(".sub-app-row").length > 5`, 20_000);
  const rows = await page.eval(`[...document.querySelectorAll(".sub-app-row")].map((b) => b.innerText)`);
  console.log("rows:", rows);
  for (const name of ["studio", "build-box"]) {
    await page.eval(`[...document.querySelectorAll(".sub-app-row")].find((b) => b.innerText.startsWith(${JSON.stringify(name)})).click()`);
    await page.waitFor(`!!document.getElementById("machine-disks")`, 20_000);
    await sleep(3500);
    await page.shot(`${out}/web-${name}.png`);
    console.log(name, await page.eval(`location.hash + "\\n" + document.querySelector(".settings-body").innerText`));
  }
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.innerText === "Settings…").click()`);
  await sleep(1500);
  console.log("Settings… →", await page.eval(`location.hash`));
} finally {
  await chrome.close();
}
