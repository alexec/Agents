// The #3453 walk: Settings ▸ Machines ▸ Processes on the page. Pairs, opens Settings, shoots the list of
// machines, opens each machine's processes and shoots them, then presses a session's link and checks the
// page went to that session.
//
//   node Web/test/walk/processes3453.mjs <WEB_URL> <browser code> <out dir> <profile>
//
// It waits after pairing until <out dir>/go-on exists.

import { existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, profile] = process.argv.slice(2);
const chrome = await launch({ profile });

const openMachine = (name) => `(() => {
  const row = [...document.querySelectorAll("section[aria-labelledby=settings-processes] .setting")]
    .find((r) => r.querySelector("span")?.innerText === ${JSON.stringify(name)});
  const button = row?.querySelector("button");
  if (!button) return false;
  if (button.innerText !== "Hide") button.click();
  return true;
})()`;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  // Until the window has approved this browser into the lock, and the sessions and the second machine are set up.
  while (!existsSync(`${out}/go-on`)) await sleep(1000);
  // Again, in the lock now, so nothing refused before the approval is left on the page.
  await page.eval(`location.reload()`);
  await sleep(1000);
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`!!document.getElementById("settings-processes")`, 20_000);
  await page.eval(`document.getElementById("settings-processes").scrollIntoView()`);
  await sleep(500);
  await page.shot(`${out}/web-machines.png`);
  const names = await page.eval(`[...document.querySelectorAll("section[aria-labelledby=settings-processes] .setting > span")].map((s) => s.innerText)`);
  console.log("machines:", names);
  for (const name of names) {
    if (!(await page.eval(openMachine(name)))) throw new Error(`no row for ${name}`);
    await page.waitFor(`[...document.querySelectorAll("h3")].some((h) => h.innerText === ${JSON.stringify(`Processes on ${name}`)})
      && !document.querySelector(".settings-body").innerText.includes("Loading…")`, 15_000);
    await sleep(3500);
    await page.eval(`[...document.querySelectorAll("h3")].find((h) => h.innerText === ${JSON.stringify(`Processes on ${name}`)}).scrollIntoView()`);
    await sleep(300);
    await page.shot(`${out}/web-${name.toLowerCase().replace(/[^a-z0-9]+/g, "-")}.png`);
    console.log(name, await page.eval(`document.querySelector("[id^=settings-processes-]").closest("section").innerText`));
  }
  const link = await page.eval(`(() => { const b = document.querySelector("[id^=settings-processes-]").closest("section").querySelector("button.link"); if (!b) return null; const t = b.innerText; b.click(); return t; })()`);
  await sleep(1500);
  console.log("pressed", link, "→", await page.eval(`location.hash`));
} finally {
  await chrome.close();
}
