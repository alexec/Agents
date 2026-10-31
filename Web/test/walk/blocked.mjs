// The #157 walk: a blocked agent's wait lines on the page. Its row and its chat say what it
// waits on, any of or all of, each agent's state and when it checks again, as the window's row
// does. Needs a scratch root with blocked agents titled "Lead, all of" and "Lead, any of" in
// folder "work".
//
//   node Web/test/walk/blocked.mjs <WEB_URL> <browser code> <out dir> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, width = "1440"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/157-blocked-chrome-${process.pid}` });
const row = (title) => `[...document.querySelectorAll(".session")].find((e) => e.querySelector(".title")?.textContent.includes(${JSON.stringify(title)}))`;
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  // The one sidebar (#151), from 760 wide: a folder folds open on its sessions.
  await page.waitFor(`document.querySelector(".row.folder")`);
  await page.eval(`[...document.querySelectorAll(".row.folder")].find((e) => e.textContent.includes("work"))?.querySelector(".disclosure[aria-expanded=false]")?.click()`);
  for (const title of ["Lead, all of", "Lead, any of"]) {
    await page.waitFor(`${row(title)}?.querySelector(".wait-line")`, 30_000);
    console.log(`row "${title}": ${await page.eval(`[...${row(title)}.querySelectorAll(".wait-line")].map((e) => e.textContent).join(" | ")`)}`);
  }
  await page.shot(`${out}/web-rows-${width}.png`);
  for (const [title, name] of [["Lead, all of", "all"], ["Lead, any of", "any"]]) {
    await page.eval(`${row(title)}.click()`);
    await page.waitFor(`document.querySelector(".chat .column-head h1")?.textContent.includes(${JSON.stringify(title)}) && document.querySelector(".block-wait-card")`, 20_000);
    await new Promise((done) => setTimeout(done, 800));
    console.log(`chat "${title}": ${await page.eval(`[...document.querySelectorAll(".block-wait-card .wait-card-event")].map((e) => e.textContent).join(" | ")`)}; button: ${await page.eval(`document.querySelector(".block-wait-card .wait-answers button").title`)}`);
    await page.shot(`${out}/web-chat-${name}-${width}.png`);
  }
} finally {
  await chrome.close();
}
