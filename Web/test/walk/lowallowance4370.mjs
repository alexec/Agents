// The #4370 walk, on a scratch root whose Claude sign-in was given a reading with 8% left by
// pool/applyAllowances: Status ▸ Runtimes has a mark in the warning tint and the grey line
// "Claude: 8% left". Screenshots go to <out dir> as web-<state>.png. The browser joins the scratch
// root's lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/lowallowance4370.mjs <WEB_URL> <browser code> <out dir> <state> <line> [profile]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, state, line, profile] = process.argv.slice(2);
let failed = 0;
const check = (ok, words) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${words}`); };

const asked = `document.body.innerText.includes("Approve this device")`;

/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
async function joinLock() {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
}

const chrome = await launch({ profile: profile ?? `/tmp/lowallowance4370-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.viewport(1300, 860);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await joinLock();
  await page.eval(`location.hash = "#/status/runtimes"`);
  await page.waitFor(`document.querySelector(".sub-app-list")`, 20_000);
  if (line) {
    await page.waitFor(`document.querySelector(".page-need")?.innerText === ${JSON.stringify(line)}`, 20_000);
    const mark = await page.eval(`document.querySelector(".sub-app-row .attention")?.getAttribute("title")`);
    check(mark === line, `the mark's title: ${mark}`);
    const tint = await page.eval(`getComputedStyle(document.querySelector(".sub-app-row .attention")).color`);
    check(tint !== "", `the mark's colour: ${tint}`);
  } else {
    await new Promise((done) => setTimeout(done, 3000));
    check(await page.eval(`document.querySelector(".page-need") === null`), "no line");
  }
  await page.shot(`${out}/web-${state}.png`);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(await page.eval(`document.body.innerText.slice(0, 600)`));
  throw e;
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
