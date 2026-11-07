// The #3785 walk on a scratch root with a fake Bitbucket (BITBUCKET_API_URL on the host): a
// Bitbucket folder's Connectors page before connecting, the Connect Bitbucket dialog empty and
// with a wrong token, the connection's row on Connectors, and the folder's three slots read.
// Screenshots go to <out dir>. The browser joins the scratch root's lock with the recovery key its
// window showed (RECOVERY_KEY).
//
//   node Web/test/walk/bitbucket3785.mjs <WEB_URL> <browser code> <folder path> <email> <token> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, email, token, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
// A field's value, as a person types it: Preact reads it from the input event.
const fill = (selector, value) => `(() => { const i = document.querySelector(${JSON.stringify(selector)});
  i.value = ${JSON.stringify(value)}; i.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`;

const chrome = await launch({ profile: `/tmp/bb3785-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`[...document.querySelectorAll("a, button")].some((e) => e.textContent.trim() === "Agents")`, 20_000);
const folderPage = "#/h/mac/p/" + encodeURIComponent(`file://${folderPath}/`) + "/m/1";
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
  await page.waitFor(`document.body.innerText.includes("Agents")`, 20_000);
};
const openFolder = async () => {
  await page.eval(`location.hash = ${JSON.stringify(folderPage)}`);
  await joinLock();
  await page.waitFor(has("Set up · "), 20_000).catch(async (e) => {
    await page.shot(`${out}/web-failed.png`);
    say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 300)}`);
    throw e;
  });
  await page.waitFor(`!document.body.textContent.includes("Reading…")`, 20_000).catch(() => null);
};

await openFolder();
check((await page.text(".connector-setup")).includes("Connect Bitbucket once"), "the folder asks to connect Bitbucket");
await page.shot(`${out}/web-folder-not-connected.png`);

await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
await page.waitFor(has("Connect Bitbucket…"), 10_000);
await page.press("Connect Bitbucket…");
await page.waitFor(has("Atlassian email"), 5_000);
await page.shot(`${out}/web-dialog-empty.png`);

await page.eval(fill(".token-form input[type=email]", email));
await page.eval(fill(".token-form input[type=password]", "wrong-token"));
await page.press("Connect");
await page.waitFor(has("did not take"), 10_000);
check(true, "a wrong token is refused");
await page.shot(`${out}/web-dialog-error.png`);

await page.eval(fill(".token-form input[type=password]", token));
await page.press("Connect");
await page.waitFor(has("bitbucket.org · Token"), 10_000);
check(true, "the row says bitbucket.org · Token");
await page.shot(`${out}/web-your-connectors.png`);

await openFolder();
const text = await page.text(".connector-setup");
check(text.includes("Walk the Connect Bitbucket sheet") && text.includes("Add a hello file") && text.includes("Checks on main"), "the three slots read");
say(`page: ${text.replace(/\s+/g, " ").slice(0, 400)}`);
await page.shot(`${out}/web-folder-connected.png`);

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
