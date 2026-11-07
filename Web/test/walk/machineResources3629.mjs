// The #3629 walk: a machine's runtimes and resources on its page. Pairs, opens Machines, checks there is no
// Machines ▸ Resources, shoots This Mac's page at its Runtimes and at its Resources, and checks the address from
// before #3629 goes to Machines.
//
//   node Web/test/walk/machineResources3629.mjs <WEB_URL> <browser code> <out dir> <profile>
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
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelectorAll(".sub-app-row").length > 2`, 20_000);
  const rows = await page.eval(`[...document.querySelectorAll(".sub-app-row")].map((b) => b.innerText)`);
  console.log("rows:", JSON.stringify(rows));
  if (rows.some((r) => r.startsWith("Resources"))) throw new Error("Machines ▸ Resources is still there");
  await page.eval(`document.querySelectorAll(".sub-app-row")[1].click()`);
  await page.waitFor(`document.querySelectorAll(".machine-runtimes li").length > 0 && document.querySelector(".resources li")`, 20_000);
  await page.eval(`document.getElementById("machine-runtimes").scrollIntoView()`);
  await page.eval(hide);
  await page.shot(`${out}/web-runtimes.png`);
  console.log(await page.eval(`document.querySelector(".machine-runtimes").innerText`));
  await page.eval(`document.getElementById("machine-resources").scrollIntoView()`);
  await page.eval(hide);
  await page.shot(`${out}/web-resources.png`);
  console.log(await page.eval(`document.querySelector(".resources").innerText`));
  // The address from before #3629 goes to Machines.
  await page.eval(`location.hash = "#/a/resources"`);
  await sleep(1500);
  console.log("#/a/resources →", await page.eval(`location.hash`));
} finally {
  await chrome.close();
}
