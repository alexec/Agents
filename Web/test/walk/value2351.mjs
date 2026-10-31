// The #2351 walk of Reports ▸ Value on a scratch control plane whose store holds a machine's
// lineage nodes (v1/lineage/<host>.json): the headline, waste and lead time, then each issue and
// milestone. Shots go to <out dir>.
//
//   node Web/test/walk/value2351.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".reports-pane")`;

const chrome = await launch({ profile: `/tmp/run-r2351-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/reports/value"`);
  await page.waitFor(`${pane}?.textContent.includes("on issues and pull requests") || ${pane}?.textContent.includes("No work on issues")`, 20_000);
  const said = (await page.text(".reports-pane")).replace(/\s+/g, " ");
  check(said.includes("a merged pull request") && said.includes("wasted"), `the headline and the waste: ${said.slice(0, 240)}`);
  check(said.includes("Issues") && said.includes("Milestones"), "the issues and the milestones");
  await page.shot(`${out}/web-value.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
