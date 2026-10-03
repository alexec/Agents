// The 074 walk: a project's Dashboard on the web page. Pairs, opens project "work", picks the
// Dashboard row, and shoots the page; with a tile id, removes the tile with that title through its ··· menu and
// shoots again, then waits for it to come back (its keeper's next post) and shoots a third time.
//
//   node Web/test/walk/dashboard.mjs <WEB_URL> <browser code> <out dir> [remove-title] [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, removeTitle = "", width = "1440"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/074-dashboard-chrome-${process.pid}` });
const tiles = `[...document.querySelectorAll(".dashboard-page .tile")].map((t) => t.getAttribute("aria-label"))`;
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".projects .row")`);
  await page.eval(`[...document.querySelectorAll(".projects .row")].find((e) => e.textContent.includes("work"))?.click()`);
  await page.waitFor(`document.querySelector(".dashboard-row")`);
  console.log(`row: ${await page.text(".dashboard-row")}`);
  await page.eval(`document.querySelector(".dashboard-row").click()`);
  await page.waitFor(`document.querySelectorAll(".dashboard-page .tile").length > 0`, 20_000);
  await new Promise((done) => setTimeout(done, 500));
  console.log(`tiles: ${JSON.stringify(await page.eval(tiles))}`);
  await page.shot(`${out}/074-web-dashboard-${width}.png`);
  if (removeTitle) {
    const label = removeTitle;
    await page.eval(`[...document.querySelectorAll(".dashboard-page .tile")].find((t) => t.getAttribute("aria-label") === ${JSON.stringify(label)}).querySelector(".tile-menu").click()`);
    await page.eval(`[...document.querySelectorAll(".dashboard-page .popover [role=menuitem]")].find((b) => b.textContent === "Remove").click()`);
    await page.waitFor(`!${tiles}.includes(${JSON.stringify(label)})`, 10_000);
    console.log(`after remove: ${JSON.stringify(await page.eval(tiles))}`);
    await page.shot(`${out}/074-web-removed-${width}.png`);
    console.log("waiting for the keeper's next post…");
    await page.waitFor(`${tiles}.includes(${JSON.stringify(label)})`, 300_000);
    await new Promise((done) => setTimeout(done, 500));
    console.log(`back: ${JSON.stringify(await page.eval(tiles))}`);
    await page.shot(`${out}/074-web-back-${width}.png`);
  }
} finally {
  await chrome.close();
}
