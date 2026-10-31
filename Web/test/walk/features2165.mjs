// The #2165 walk of Reports ▸ Features on a scratch set-up whose host counted some features
// (<root>/features-history.json): the note, unused features marked, then the most used, with
// their clients. Shots go to <out dir>.
//
//   node Web/test/walk/features2165.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".reports-pane")`;

const chrome = await launch({ profile: `/tmp/run-f2165-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/reports/features"`);
  await page.waitFor(`${pane}?.textContent.includes("least used first")`, 20_000);
  const said = (await page.text(".reports-pane")).replace(/\s+/g, " ");
  check(said.includes("Not used") && said.includes("in 90 days"), `unused marked: ${said.slice(0, 240)}`);
  check(said.includes("agent, mac, workflow"), "a feature's clients");
  await page.shot(`${out}/web-features.png`);
  await page.eval(`window.scrollTo(0, document.body.scrollHeight); document.querySelectorAll("*").forEach((e) => { if (e.scrollHeight > e.clientHeight + 10) e.scrollTop = e.scrollHeight; })`);
  await page.shot(`${out}/web-features-most-used.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
