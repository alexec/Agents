// The #1336 walk on a scratch root: a folder's Connectors page opens with its set-up (frame F,
// the Mac's grid of six slots), Skip and Set Up go through the host, the Connect GitHub sheet
// shows the host's device-flow code (frame B), and Connectors lists the connections (frame E).
// Screenshots go to <out dir>; the sign-in is left waiting, so a person can approve the code it
// prints. The browser joins the scratch root's lock with the recovery key its window showed
// (RECOVERY_KEY), when it asks.
//
//   [RECOVERY_KEY=…] node Web/test/walk/connect1336.mjs <WEB_URL> <browser code> <folder name> <out dir> [stop]
//
// With "stop", it stops after the page, before Connect GitHub.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out, stop] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;

const chrome = await launch({ profile: `/tmp/connect1336-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
// The folder's group in the sidebar, by its role and its name; the group carries the folder's address.
const group = `[...document.querySelectorAll('nav[aria-label="Sidebar"] [role="group"]')]
  .find((g) => g.getAttribute("aria-label") === ${JSON.stringify(folderName)})`;
const asked = `document.body.innerText.includes("Approve this device on another of your devices.")`;
/** Joins the lock when the page asks, with the recovery key, and opens the page again. */
const joinLock = async () => {
  if (!await page.waitFor(asked, 5_000).then(() => true, () => false)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  // What it read before it was in the lock was refused: read it all again.
  await page.eval(`location.reload()`);
  await sleep(1000);
};
const failedAt = async (e) => {
  await page.shot(`${out}/1336-web-failed.png`);
  say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 300)}`);
  throw e;
};
// The page opens on the Overview; the folders are under Agents, which asks to join the lock.
await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
await page.eval(`location.hash = "#/agents"`);
await joinLock();
await page.waitFor(`!!${group}`, 20_000).catch(failedAt);
// The folder's Connectors page, by its address.
const folder = await page.eval(`${group}.dataset.folder`);
await page.eval(`location.hash = ${JSON.stringify(`#/h/mac/p/${encodeURIComponent(folder)}/m/1`)}`);
await page.waitFor(has("Set up · "), 20_000).catch(failedAt);
await page.waitFor(`!document.body.textContent.includes("Reading…")`, 20_000).catch(() => null);
const text = await page.text(".connector-setup");
check(["Tasks", "Code review", "CI", "Docs", "Messaging", "Where agents run"].every((slot) => new RegExp(slot, "i").test(text)),
  "the six slots are there");
say(`page: ${text.replace(/\s+/g, " ").slice(0, 400)}`);
await page.shot(`${out}/1336-web-a-page.png`);

// Skip, then Set Up, through the host.
await page.press("Skip");
await page.waitFor(has("Skipped"), 10_000);
check(true, "a slot skipped");
await page.shot(`${out}/1336-web-g-skipped.png`);
await page.press("Set Up");
await page.waitFor(`!document.body.textContent.includes("Skipped")`, 10_000);
check(true, "set up again");

if (stop !== "stop" && text.includes("Connect GitHub…")) {
  await page.press("Connect GitHub…");
  await page.waitFor(has("Agents will be able to"), 5_000);
  await page.press("Continue on github.com");
  await page.waitFor(`document.querySelector(".user-code")`, 20_000);
  const userCode = await page.text(".user-code");
  check(/^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(userCode.trim()), `the code: ${userCode}`);
  await page.shot(`${out}/1336-web-b-sheet.png`);
}

await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
// Each connection with Disconnect, and a Connect row for each provider not connected.
await page.waitFor(`document.querySelector(".connections li")`, 10_000);
say(`your connectors: ${(await page.text(".connections")).replace(/\s+/g, " ")}`);
await page.shot(`${out}/1336-web-e-your-connectors.png`);

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
