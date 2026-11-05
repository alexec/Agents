// The #3438 walk, on a scratch root whose Claude sign-in was given weekly readings by
// pool/applyAllowances: the Runtimes page says the week against an even pace under Claude's
// reading, then Past weeks, a bar per week that has reset. Screenshots go to <out dir>.
//
//   node Web/test/walk/pace3438.mjs <WEB_URL> <browser code> <out dir> [profile]

import { launch } from "./cdp.mjs";

const [webURL, code, out, profile] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

const chrome = await launch({ profile: profile ?? `/tmp/pace3438-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.viewport(1300, 860);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  await page.eval(`location.hash = "#/a/runtimes"`);
  await page.waitFor(`document.body.innerText.includes("even pace")`, 20_000);
  const text = await page.eval(`document.body.innerText`);
  check(text.includes("3 days to go · used faster than an even pace (43% left)"), "the pace line");
  const bars = await page.eval(`document.querySelectorAll(".runtime-list .past-weeks .week-bar").length`);
  check(bars === 3, `a bar per past week: ${bars}`);
  const label = await page.eval(`document.querySelector(".runtime-list .past-weeks")?.getAttribute("aria-label")`);
  check(label === "Past weeks: 58%, 71%, 100% used", `read as: ${label}`);
  await page.shot(`${out}/web-pace.png`);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(await page.eval(`document.body.innerText.slice(0, 600)`));
  throw e;
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
