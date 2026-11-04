// The #3395 walk: the daily summary's control on Settings ▸ Workflows. Pairs, shoots Summary only,
// chooses Summary and checks and then Every 6 hours from the page, and shoots each; the Daily checks
// workflow file is printed after each, to show the page changed it on the Mac's host.
//
//   node Web/test/walk/dailychecks3395.mjs <WEB_URL> <browser code> <checks workflow file> <out dir>

import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, file, out] = process.argv.slice(2);
const front = () => readFileSync(file, "utf8").split("\n---")[0];
const chrome = await launch({ profile: `/tmp/3395-dailychecks-chrome-${process.pid}` });

// A menu's choice by its visible name, sent as the person's pick is.
const choose = (page, label, name) => page.eval(`(() => {
  const s = [...document.querySelectorAll(".daily-summary label")].find((l) => l.querySelector("span")?.textContent === ${JSON.stringify(label)})?.querySelector("select");
  const o = s && [...s.options].find((o) => o.textContent === ${JSON.stringify(name)});
  if (!o) return false;
  s.value = o.value; s.dispatchEvent(new Event("change", { bubbles: true })); return true;
})()`);

try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`!!document.querySelector(".daily-summary")`, 20_000);
  await page.eval(`document.querySelector(".daily-summary").scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/web-summary-only.png`);

  if (!await choose(page, "Daily summary", "Summary and checks")) throw new Error("no Summary and checks");
  await page.waitFor(`[...document.querySelectorAll(".daily-summary span")].some((s) => s.textContent === "Checks")`, 10_000);
  await sleep(500);
  console.log(`summary and checks:\n${front()}`);
  await page.eval(`document.querySelector(".daily-summary").scrollIntoView({ block: "center" })`);
  await page.shot(`${out}/web-checks.png`);

  if (!await choose(page, "Checks", "Every 6 hours")) throw new Error("no Every 6 hours");
  await sleep(1500);
  console.log(`every 6 hours:\n${front()}`);
  await page.shot(`${out}/web-checks-every-6.png`);
} finally {
  await chrome.close();
}
