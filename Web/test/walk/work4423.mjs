// Work look: Releases on the web page (#4423): on a run-app root whose lineage links pull requests part-of the releases
// v1.1.0, v1.2.0 and v1.3.0 of example/shop, a CI run that builds v1.3.0 and its TestFlight deploy, open Work ▸
// Releases (Newest is the version, Latest on v1.3.0), open v1.3.0's page at 1280, 800 and 390 px, and on a phone its
// Pull requests row. Screenshots into <out dir>.
//
//   node Web/test/walk/work4423.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
// PROFILE: a browser already in the root's machine lock (#3490), as the first to pair is; its pairing is kept.
const chrome = await launch({ profile: process.env.PROFILE ?? `/tmp/w4423-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 860 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const titles = () => page.eval(`[...document.querySelectorAll(".work-row .work-title")].map((t) => t.textContent)`);
const text = (sel) => page.eval(`document.querySelector(${JSON.stringify(sel)})?.textContent ?? ""`);

try {
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".nav-item")`);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/work/release"`);
  await page.waitFor(`document.querySelectorAll(".work-row .work-title").length >= 3`, 30_000);
  ok(`Releases by version: ${await titles()}`, JSON.stringify(await titles()) === JSON.stringify(["v1.3.0", "v1.2.0", "v1.1.0"]));
  ok("v1.3.0 is the latest", await page.eval(`document.querySelector(".work-row .work-release-chip")?.closest("li").dataset.ref.endsWith("v1.3.0")`));
  await sleep(400);
  await page.shot(`${out}/web-releases.png`);

  await page.eval(`[...document.querySelectorAll(".work-row")].find((r) => r.textContent.includes("v1.3.0"))?.click()`);
  await page.waitFor(`document.querySelectorAll(".work-release-pulls .work-row").length === 4`, 30_000);
  ok(`the address: ${await page.eval("location.hash")}`, (await page.eval("location.hash")).startsWith("#/work/release/github%3Aexample%2Fshop%2Frelease%2Fv1.3.0"));
  ok(`the state line: ${await text(".work-page-byline")}`, (await text(".work-page-byline")).includes("4 pull requests · v1.2.0…v1.3.0"));
  ok(`the stepper: ${await text(".work-stepper")}`, (await text(".work-stepper")).includes("1 of 3"));
  ok(`the pipeline: ${await text(".work-side")}`, (await text(".work-side")).includes("CI run") && (await text(".work-side")).includes("TestFlight 57"));
  await sleep(600);
  await page.shot(`${out}/web-release.png`);

  await page.viewport(800, 1000);
  await sleep(500);
  await page.shot(`${out}/web-release-800.png`);

  await page.viewport(390, 844);
  await sleep(500);
  await page.shot(`${out}/web-release-390.png`);
  await page.eval(`document.querySelector(".work-files-row button").click()`);
  await page.waitFor(`document.querySelector(".work-release-pulls-title")`, 10_000);
  await sleep(400);
  await page.shot(`${out}/web-release-pulls-390.png`);
  await page.eval(`document.querySelector(".work-release-back").click()`);
  await page.waitFor(`document.querySelector(".work-release-notes")`, 10_000);

  await page.eval(`location.hash = "#/work/release"`);
  await page.waitFor(`document.querySelectorAll(".work-row .work-title").length >= 3`, 30_000);
  await sleep(400);
  await page.shot(`${out}/web-releases-390.png`);
} finally {
  await chrome.close();
}
