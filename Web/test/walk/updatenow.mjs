// The #146 walk: Update now on the web page's Dashboard. Pairs, opens project "work", picks the
// Dashboard row and shoots the title line. With "press", presses Update now, shoots it running,
// waits for the run to end and the tiles to arrive, and shoots again.
//
//   node Web/test/walk/updatenow.mjs <WEB_URL> <browser code> <out dir> <prefix> [press] [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix, press = "", width = "1440"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/146-update-chrome-${process.pid}` });
const state = `({ button: document.querySelector(".update-now")?.textContent, disabled: document.querySelector(".update-now")?.disabled,
  line: document.querySelector(".update-line")?.textContent ?? null,
  tiles: [...document.querySelectorAll(".dashboard-page .tile")].map((t) => t.getAttribute("aria-label")) })`;
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".projects .row")`);
  await page.eval(`[...document.querySelectorAll(".projects .row")].find((e) => e.textContent.includes("work"))?.click()`);
  await page.waitFor(`document.querySelector(".dashboard-row")`);
  await page.eval(`document.querySelector(".dashboard-row").click()`);
  await page.waitFor(`document.querySelector(".update-now")`, 20_000);
  await new Promise((done) => setTimeout(done, 500));
  console.log(`before: ${JSON.stringify(await page.eval(state))}`);
  await page.shot(`${out}/${prefix}-before-${width}.png`);
  if (press) {
    await page.eval(`document.querySelector(".update-now").click()`);
    await page.waitFor(`document.querySelector(".update-now")?.textContent === "Updating…"`, 20_000);
    console.log(`running: ${JSON.stringify(await page.eval(state))}`);
    await page.eval(`document.querySelector(".update-now").click()`);
    await page.shot(`${out}/${prefix}-running-${width}.png`);
    await page.waitFor(`document.querySelectorAll(".dashboard-page .tile").length >= 3`, 300_000);
    console.log(`tiles in: ${JSON.stringify(await page.eval(state))}`);
    await page.waitFor(`document.querySelector(".update-now")?.textContent !== "Updating…"`, 300_000);
    await new Promise((done) => setTimeout(done, 1500));
    console.log(`after: ${JSON.stringify(await page.eval(state))}`);
    await page.shot(`${out}/${prefix}-after-${width}.png`);
  }
} finally {
  await chrome.close();
}
