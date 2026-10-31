// The #2019 M9 walk: Console ▸ Live Now on a scratch control plane whose machine runs one agent
// (never a real record). Opens the page, checks the agent's row, shoots it, presses Stop and waits
// for the board to empty.
//
//   node Web/test/walk/live2019.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

const chrome = await launch({ profile: `/tmp/run-m9live-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/console/live"`);
  await page.waitFor(`document.querySelector(".console-table")?.textContent.includes("Local owner")`, 30_000);
  const said = (await page.text(".team-workflows")).replace(/\s+/g, " ");
  console.log(said.slice(0, 600));
  check(/1 agent on 1 machine/.test(said), "the summary counts the agent");
  check(/Working|Waiting for its person|Starting/.test(said), "the row says its state");
  await page.shot(`${out}/web-live.png`);
  await page.press("Stop");
  await page.waitFor(`document.querySelector(".team-workflows")?.textContent.includes("No agent is running now")`, 60_000);
  check(true, "Stop ends the agent and the board empties");
  await page.shot(`${out}/web-live-stopped.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
