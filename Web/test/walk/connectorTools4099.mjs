// The #4099 walk on a scratch root: a folder's Connectors page, Tools on a connector, each tool with
// Allow, Ask or Off, and one changed through the host. Screenshots go to <out dir>. The browser joins
// the scratch root's lock with the recovery key its window showed (RECOVERY_KEY), when it asks, or waits for
// the window to approve it.
//
//   [RECOVERY_KEY=…] node Web/test/walk/connectorTools4099.mjs <WEB_URL> <browser code> <folder name> <connector> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderName, connector, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;

const chrome = await launch({ profile: `/tmp/connectorTools4099-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  const group = `[...document.querySelectorAll('nav[aria-label="Sidebar"] [role="group"]')]
    .find((g) => g.getAttribute("aria-label") === ${JSON.stringify(folderName)})`;
  const asked = `document.body.innerText.includes("Approve this device on another of your devices.")`;
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  await page.eval(`location.hash = "#/agents"`);
  if (await page.waitFor(asked, 5_000).then(() => true, () => false) && !process.env.RECOVERY_KEY) {
    // Approved on the scratch window instead (walk.py: "=Compare Digits", then "=Approve").
    say("waiting for the window to approve this browser");
    await page.waitFor(`!${asked}`, 90_000);
    await page.eval(`location.reload()`);
    await sleep(1000);
  } else if (await page.waitFor(asked, 1_000).then(() => true, () => false)) {
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!${asked}`, 30_000);
    await page.eval(`location.reload()`);
    await sleep(1000);
  }
  await page.waitFor(`!!${group}`, 20_000);
  const folder = await page.eval(`${group}.dataset.folder`);
  await page.eval(`location.hash = ${JSON.stringify(`#/h/mac/p/${encodeURIComponent(folder)}/m/1`)}`);
  await page.waitFor(has(connector), 20_000);
  await page.shot(`${out}/web-closed.png`);
  await page.press("Tools");
  await page.waitFor(`!!document.querySelector(".connector-tools li")`, 20_000);
  const text = await page.text(".connector-tools");
  check(text.includes("Tools that write") && text.includes("writes"), "the tools and the switch are there");
  say(`tools: ${text.replace(/\s+/g, " ").slice(0, 400)}`);
  await page.shot(`${out}/web-tools.png`);
  // Tools that write: Off, through the host.
  await page.eval(`(() => { const s = document.querySelector('.writes-switch select'); s.value = "off";
    s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelector('.writes-switch select').value === "off" &&
    [...document.querySelectorAll('.connector-tools li select')].some((s) => s.selectedOptions[0]?.textContent === "Default (Off)")`, 10_000);
  check(true, "Tools that write set to Off");
  await page.shot(`${out}/web-writes-off.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
