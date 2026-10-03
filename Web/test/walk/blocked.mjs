// The #157 walk: a blocked agent's wait lines on the page. Its row and its chat say what it
// waits on, any of or all of, each agent's state and when it checks again, as the window's row
// does. Needs a scratch root with blocked agents titled "Lead, all of" and "Lead, any of" in
// project "work".
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
  // The one sidebar (#151), from 760 wide: a project folds open on its sessions.
  await page.waitFor(`document.querySelector(".row.project")`);
  await page.eval(`[...document.querySelectorAll(".row.project")].find((e) => e.textContent.includes("work"))?.querySelector(".disclosure[aria-expanded=false]")?.click()`);
  for (const title of ["Lead, all of", "Lead, any of"]) {
    await page.waitFor(`${row(title)}?.querySelector(".wait-line")`, 30_000);
    console.log(`row "${title}": ${await page.eval(`[...${row(title)}.querySelectorAll(".wait-line")].map((e) => e.textContent).join(" | ")`)}`);
  }
  await page.shot(`${out}/web-rows-${width}.png`);
  for (const [title, name] of [["Lead, all of", "all"], ["Lead, any of", "any"]]) {
    await page.eval(`${row(title)}.click()`);
    await page.waitFor(`document.querySelector(".chat .column-head h1")?.textContent.includes(${JSON.stringify(title)}) && document.querySelector(".block-strip")`, 20_000);
    await new Promise((done) => setTimeout(done, 800));
    console.log(`chat "${title}": ${await page.eval(`[...document.querySelectorAll(".block-strip li")].map((e) => e.textContent).join(" | ")`)}; button: ${await page.eval(`document.querySelector(".block-strip .carry-on").title`)}`);
    await page.shot(`${out}/web-chat-${name}-${width}.png`);
  }
} finally {
  await chrome.close();
}
