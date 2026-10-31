// The #2019 read API walk: on a scratch control plane, Console ▸ Read API makes a token and shows
// it once, lists it, and revokes it. Prints the token's value and the URL, so a curl can read the
// reports with it before the revoke (READAPI_PAUSE_FILE: the walk waits until that file exists).
//
//   node Web/test/walk/readapi2019.mjs <WEB_URL> <browser code> <out dir>

import { existsSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const body = (page) => page.text("body").then((t) => t.replace(/\s+/g, " "));

const chrome = await launch({ profile: `/tmp/run-readapi-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/console/readApi"`);
  await page.waitFor(`document.body.textContent.includes("No tokens yet")`, 10_000);
  check(/OTLP Exporter/.test(await body(page)), "the exporter's section is there");
  await page.focus(`input[aria-label="Token name"]`);
  await page.type("Looker");
  await page.press("Make Token");
  await page.waitFor(`document.querySelector(".read-token-value")`, 10_000);
  const value = (await page.text(".read-token-value")).trim();
  check(value.startsWith("agread_"), "the value is shown once");
  console.log(`TOKEN=${value}`);
  await page.shot(`${out}/web-readapi-made.png`);
  const pause = process.env.READAPI_PAUSE_FILE;
  if (pause) {
    for (let i = 0; i < 120 && !existsSync(pause); i++) await new Promise((r) => setTimeout(r, 500));
  }
  await page.press("Done");
  await page.eval(`location.hash = "#/console/audit"`);
  await page.eval(`location.hash = "#/console/readApi"`);
  await page.waitFor(`document.body.textContent.includes("Looker")`, 10_000);
  const listed = await body(page);
  check(!listed.includes(value), "the value is not shown again");
  check(/Made by .* at \d\d:\d\d\./.test(listed), "who made it, and when");
  await page.shot(`${out}/web-readapi-listed.png`);
  await page.eval(`window.confirm = (m) => { window.asked = m; return true; }`);
  await page.press("Revoke…");
  check(/^Revoke Looker\?/.test(await page.eval(`window.asked`)), "Revoke… asks first (#2438)");
  await page.waitFor(`document.body.textContent.includes("Revoked at")`, 10_000);
  check(true, "Revoke marks it revoked");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await body(page).catch(() => "")).slice(0, 2000));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
