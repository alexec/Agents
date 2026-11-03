// Work ▸ Features (#3269): on a run-app root whose folder is on the fixture GitHub (forge3269-github.py,
// AGENTS_TEST_GITHUB_URL), open Work ▸ Features and see a row per feature: label with its counts; open
// checkout and accounts and see their open epics with progress and lead, and checkout's issue with no
// epic; open an epic's page and come Back to the list as it was. Screenshots into <out dir>.
//
//   node Web/test/walk/features3269.mjs <WEB_URL> <browser code> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-feat3269-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/features"`);
  await page.waitFor(`document.querySelectorAll(".work-feature-head").length === 2`, 30_000);
  const heads = await text(".work-feature-head");
  ok(`the features: ${heads.join(" | ")}`, heads[0].includes("Accounts") && heads[1].includes("3 epics · 2 open"));
  await sleep(500);
  await page.shot(`${out}/${prefix}-features.png`);

  await page.eval(`document.querySelectorAll(".work-feature-head").forEach((b) => b.click())`);
  await page.waitFor(`document.querySelectorAll(".work-feature-row").length === 4`, 30_000);
  const rows = await text(".work-feature-row");
  ok(`the rows: ${rows.join(" | ")}`, rows.some((r) => r.includes("#40") && r.includes("2/5") && r.includes("lead")) && rows.some((r) => r.includes("#55")));
  await sleep(500);
  await page.shot(`${out}/${prefix}-features-open.png`);

  await page.eval(`[...document.querySelectorAll(".work-feature-row")].find((b) => b.textContent.includes("#50")).click()`);
  await page.waitFor(`location.hash.startsWith("#/work/issue/")`, 10_000);
  ok("a row opens the epic's page", true);
  await page.eval(`history.back()`);
  await page.waitFor(`document.querySelectorAll(".work-feature-row").length === 4`, 10_000);
  ok("Back finds the features open as they were", true);
} finally {
  await chrome.close();
}
