// The #3802 walk on a scratch root with the fixture Azure DevOps (.agents/skills/run-app/scripts/fake-azure-devops.py):
// the one token sheet as Connect Azure DevOps (empty, a wrong token, a token that connects), the
// connection's row on Connectors, the Azure DevOps folder's three slots read, and the same sheet as
// Connect Forgejo and Connect Bitbucket. The host has no Azure DevOps connection at the start.
// Screenshots go to <out dir>. The browser joins the scratch root's lock with the recovery key its
// window showed (RECOVERY_KEY).
//
//   node Web/test/walk/azuredevops3802.mjs <WEB_URL> <browser code> <folder path> <organization> <token> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, organization, token, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
// A field's value, as a person types it: Preact reads it from the input event.
const fill = (selector, value) => `(() => { const i = document.querySelector(${JSON.stringify(selector)});
  i.value = ${JSON.stringify(value)}; i.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`;

const chrome = await launch({ profile: `/tmp/ado3802-chrome-${process.pid}` });
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

const connectors = async () => {
  await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
  await joinLock();
  await page.waitFor(has("Connect Azure DevOps…"), 15_000).catch(async (e) => {
    await page.shot(`${out}/web-failed.png`);
    say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 600)}`);
    throw e;
  });
};
// The folder page asks to join the lock first; with no connection its remote is no forge's yet.
await openFolder();
const field = ".token-form input:not([type=password])";

for (const [name, label] of [["Forgejo", "Forgejo address"], ["Bitbucket", "Atlassian email"]]) {
  await connectors();
  await page.press(`Connect ${name}…`);
  await page.waitFor(has(label), 5_000);
  check(true, `Connect ${name} is the one token sheet, with ${label}`);
  await page.shot(`${out}/web-${name.toLowerCase()}-empty.png`);
  await page.press("Cancel");
}

await connectors();
await page.press("Connect Azure DevOps…");
await page.waitFor(has("Personal access token"), 5_000);
await page.shot(`${out}/web-azure-devops-empty.png`);

await page.eval(fill(field, organization));
await page.eval(fill(".token-form input[type=password]", "wrong-token"));
await page.press("Connect");
await page.waitFor(has("did not take the token"), 10_000);
check(true, "a wrong token is refused");
await page.shot(`${out}/web-azure-devops-error.png`);

await page.eval(fill(".token-form input[type=password]", token));
await page.press("Connect");
await page.waitFor(has("Personal access token") + " && " + has("Azure DevOps · "), 10_000);
check(true, "the row says the organization and Personal access token");
await page.shot(`${out}/web-connected.png`);

await openFolder();
const text = await page.text(".connector-setup");
check(text.includes("Azure Boards work items") && text.includes("Pay with a saved card") && text.includes("shop-ci"), "the three slots read");
say(`page: ${text.replace(/\s+/g, " ").slice(0, 400)}`);
await page.shot(`${out}/web-folder-setup.png`);

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
