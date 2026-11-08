// The #3631 walk: Status ▸ Runtimes (Your setup ▸ Runtimes until #3998), each runtime once with a line per machine.
// Pairs, checks the bar has Status and Machines has no Runtimes, shoots the page, follows a machine's line to its
// page, and checks the addresses from before #3631 and #3998 open Status.
//
//   node Web/test/walk/yourSetup3631.mjs <WEB_URL> <browser code> <out dir> <profile>
//
// It waits after pairing until <out dir>/go-on exists.

import { existsSync } from "node:fs";
import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, profile] = process.argv.slice(2);
const chrome = await launch({ profile });
// The repo is public: the scratch host is named after this Mac, so its pictures say "studio".
const real = JSON.stringify(hostname().replace(/\.local$/, ""));
const hide = `(() => {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    n.nodeValue = n.nodeValue.split(${real} + ".local").join("studio").split(${real}).join("studio");
  }
})()`;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
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
  const bar = await page.eval(`[...document.querySelectorAll(".nav-items .nav-item")].map((b) => b.innerText)`);
  console.log("bar:", JSON.stringify(bar));
  if (!bar.some((b) => b.startsWith("Status"))) throw new Error("no Status in the bar");
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelectorAll(".sub-app-row").length > 1`, 20_000);
  const rows = await page.eval(`[...document.querySelectorAll(".sub-app-row")].map((b) => b.innerText)`);
  console.log("machines rows:", JSON.stringify(rows));
  if (rows.some((r) => r.startsWith("Runtimes"))) throw new Error("Machines ▸ Runtimes is still there");
  await page.eval(`[...document.querySelectorAll(".nav-items .nav-item")].find((b) => b.innerText.startsWith("Status")).click()`);
  try {
    await page.waitFor(`document.querySelectorAll(".setup-machines li").length > 1`, 30_000);
  } catch (e) {
    await page.shot(`${out}/web-your-setup-failed.png`);
    console.log(await page.eval(`document.querySelector(".activity-page")?.innerText`));
    throw e;
  }
  await sleep(1500);
  await page.eval(hide);
  await page.shot(`${out}/web-your-setup.png`);
  console.log(await page.eval(`document.querySelector(".runtime-list").innerText`));
  // A machine's line opens its page.
  await page.eval(`document.querySelector(".setup-machines a").click()`);
  await sleep(1500);
  console.log("a machine's line →", await page.eval(`location.hash`));
  // The addresses from before #3631 and #3998 open Status.
  for (const old of ["#/a/runtimes", "#/machines/runtimes", "#/setup/runtimes"]) {
    await page.eval(`location.hash = ${JSON.stringify(old)}`);
    await sleep(1500);
    console.log(old, "→", await page.eval(`location.hash`));
  }
} finally {
  await chrome.close();
}
