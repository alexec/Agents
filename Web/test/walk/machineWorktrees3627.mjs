// The #3627 walk: a machine's worktrees on its page. Pairs, opens Machines, checks there is no Machines ▸ Worktrees,
// shoots This Mac's page at its Worktrees, presses Remove build output on the first idle worktree, shoots again, and
// checks the address from before #3627 goes to Machines.
//
//   node Web/test/walk/machineWorktrees3627.mjs <WEB_URL> <browser code> <out dir> <profile>
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
  await page.waitFor(`document.querySelectorAll(".sub-app-row").length > 3`, 20_000);
  const rows = await page.eval(`[...document.querySelectorAll(".sub-app-row")].map((b) => b.innerText)`);
  console.log("rows:", rows.length);
  if (rows.some((r) => r.startsWith("Worktrees"))) throw new Error("Machines ▸ Worktrees is still there");
  await page.eval(`document.querySelectorAll(".sub-app-row")[1].click()`);
  await page.waitFor(`document.querySelectorAll(".worktree").length > 0`, 20_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.innerText === "Refresh").click()`);
  await sleep(4000);
  await page.eval(`document.getElementById("machine-worktrees").scrollIntoView()`);
  await page.eval(hide);
  await page.shot(`${out}/web-this-mac.png`);
  console.log(await page.eval(`document.querySelector(".worktrees").innerText`));
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.innerText === "Remove build output").click()`);
  await page.waitFor(`/Freed|No build output/.test(document.body.innerText)`, 20_000);
  await sleep(1500);
  await page.eval(`document.getElementById("machine-worktrees").scrollIntoView()`);
  await page.eval(hide);
  await page.shot(`${out}/web-build-output-removed.png`);
  // The address from before #3627 goes to Machines.
  await page.eval(`location.hash = "#/a/worktrees"`);
  await sleep(1500);
  console.log("#/a/worktrees →", await page.eval(`location.hash`));
} finally {
  await chrome.close();
}
