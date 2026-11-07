// Work ▸ Features's Finished group (#3741): on a run-app root whose folder is on the fixture GitHub
// (forge3741-github.py, AGENTS_TEST_GITHUB_URL), open Work ▸ Features and see the features with open
// work at the top, reviews among them for its open bug, and a closed "Finished (2)" group at the
// bottom; open the group and see wishlist and wrapping. Screenshots into <out dir>.
//
//   node Web/test/walk/features3741.mjs <WEB_URL> <browser code> <out dir> [prefix]
//
// It waits after pairing until <out dir>/go-on exists: the window approves this browser first.

import { existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-feat3741-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  // Until the window has approved this browser into the lock.
  while (!existsSync(`${out}/go-on`)) await sleep(1000);
  await page.eval(`location.reload()`);
  await sleep(1000);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/features"`);
  await page.waitFor(`document.querySelector(".work-finished-head")`, 30_000);
  const heads = await text(".work-feature-head");
  ok(`closed: ${heads.join(" | ")}`, heads.length === 4 && heads[2].includes("1 epic · 0 open · 1 open issue") && heads[3] === "▸Finished (2)");
  await sleep(500);
  await page.shot(`${out}/${prefix}-finished-closed.png`);

  await page.eval(`document.querySelector(".work-finished-head").click()`);
  await page.waitFor(`document.querySelectorAll(".work-feature-head").length === 6`, 10_000);
  const all = await text(".work-feature-head");
  ok(`open: ${all.join(" | ")}`, all[4].includes("Wishlist") && all[5].includes("Wrapping"));
  await sleep(500);
  await page.shot(`${out}/${prefix}-finished-open.png`);
} finally {
  await chrome.close();
}
