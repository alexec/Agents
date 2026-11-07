// The #3632 walk: Your setup ▸ Connectors and Secrets. Pairs, checks Your setup lists Runtimes, Connectors and
// Secrets, Machines has no Connectors and Settings no Secrets, shoots both pages, and checks the addresses from
// before #3632 open Your setup.
//
//   node Web/test/walk/yourSetup3632.mjs <WEB_URL> <browser code> <out dir> <profile>
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
const rows = `[...document.querySelectorAll(".sub-app-row")].map((b) => b.innerText)`;

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
  await page.waitFor(`document.querySelectorAll(".sub-app-row").length > 0`, 20_000);
  console.log("machines rows:", JSON.stringify(await page.eval(rows)));
  if ((await page.eval(rows)).some((r) => r.startsWith("Connectors"))) throw new Error("Machines ▸ Connectors is still there");

  await page.eval(`location.hash = "#/setup/mcp"`);
  await page.waitFor(`document.body.innerText.toLowerCase().includes("user connectors")`, 20_000);
  const setup = await page.eval(rows);
  console.log("your setup rows:", JSON.stringify(setup));
  for (const want of ["Runtimes", "Connectors", "Secrets"]) {
    if (!setup.some((r) => r.startsWith(want))) throw new Error(`no ${want} in Your setup`);
  }
  await sleep(1500);
  await page.eval(hide);
  await page.shot(`${out}/web-connectors.png`);

  await page.eval(`location.hash = "#/setup/secrets"`);
  await page.waitFor(`document.getElementById("settings-secrets") && document.getElementById("settings-session-secrets")`, 20_000);
  await sleep(1500);
  await page.eval(hide);
  await page.shot(`${out}/web-secrets.png`);

  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`document.querySelector(".settings-page")`, 20_000);
  await sleep(1000);
  if (await page.eval(`!!document.getElementById("settings-secrets")`)) throw new Error("Settings still has Secrets");
  console.log("settings: no Secrets");

  // The addresses from before #3632 open Your setup.
  for (const old of ["#/a/mcp", "#/machines/mcp"]) {
    await page.eval(`location.hash = ${JSON.stringify(old)}`);
    await sleep(1500);
    console.log(old, "→", await page.eval(`location.hash`));
  }
} finally {
  await chrome.close();
}
