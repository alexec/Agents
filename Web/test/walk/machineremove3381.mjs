// The #3381 walk: Remove… on a machine in Settings ▸ Machines on the page. Pairs, opens Settings,
// shoots the section with Remove…, presses it, checks the question is the window's, says yes, and
// shoots the section with the machine gone. The browser's own confirm cannot be shot headless, so
// the walk records its words. Screenshots go to <out dir>.
//
//   node Web/test/walk/machineremove3381.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const section = `document.querySelector("[aria-labelledby=settings-machines]")`;

const chrome = await launch({ profile: `/tmp/run-r3381-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.textContent.includes("Settings")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`${section}?.querySelector(".setting button.destructive")`, 20_000);
  await page.eval(`${section}.scrollIntoView()`);
  const name = await page.eval(`${section}.querySelector(".setting span").textContent`);
  check(true, `the section lists ${name} with Remove…`);
  await page.shot(`${out}/web-machines.png`);

  await page.eval(`window.confirm = (q) => { window.__asked = q; return true; }`);
  await page.eval(`${section}.querySelector(".setting button.destructive").click()`);
  const asked = await page.eval(`window.__asked`);
  check(asked === `Remove ${name}? It stops connecting, and every window and device stops seeing it. Its agents are left running where they are.`,
    `asked: ${asked}`);
  await page.waitFor(`${section}.textContent.includes("No machines yet.")`, 15_000);
  check(true, "the machine left the list");
  await page.shot(`${out}/web-removed.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
