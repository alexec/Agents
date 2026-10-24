// The #1336 walk on a scratch root: a folder's Connectors page opens with its set-up (frame F,
// the Mac's grid), Skip and Set Up go through the host, the Connect GitHub sheet shows the host's
// device-flow code (frame B), and Connectors lists the connections (frame E). Screenshots go
// to <out dir>; the sign-in is left waiting, so a person can approve the code it prints.
//
//   node Web/test/walk/connect1336.mjs <WEB_URL> <browser code> <folder name> <out dir> [stop]
//
// With "stop", it stops after the page, before Connect GitHub.

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
await page.waitFor(has(folderName), 20_000);
// The folder's Connectors page, by its address (the folder's title attribute is its path).
await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent("file://" +
  document.querySelector('button[data-fold=folder]').title + "/") + "/m/1"`);
await page.waitFor(has("Set up · "), 20_000).catch(async (e) => {
  await page.shot(`${out}/1336-web-failed.png`);
  say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 300)}`);
  throw e;
});
await page.waitFor(`!document.body.textContent.includes("Reading…")`, 20_000).catch(() => null);
const text = await page.text(".connector-setup");
check(/where agents run/i.test(text) && text.includes("This Mac"), "the four slots are there");
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
await page.waitFor(`/No connections yet|Disconnect/.test(document.body.textContent)`, 10_000);
say(`your connectors: ${(await page.text(".connections")).replace(/\s+/g, " ")}`);
await page.shot(`${out}/1336-web-e-your-connectors.png`);

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
