// The #1663 walk: a sidebar search for a word only a prompt holds draws the said line in the row.
//
//   node Web/test/walk/said1663.mjs <WEB_URL> <browser code> <out dir> <word>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, word] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-said1663-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  await sleep(800);
  await page.focus(".sidebar input.search");
  await page.type(word);
  await page.waitFor(`document.querySelector(".sidebar .row.session .subtitle.said")`, 10_000);
  await sleep(300);
  console.log(await page.eval(`[...document.querySelectorAll(".sidebar .row.session")].map((r) => r.innerText)`));
  await page.shot(`${out}/said1663-web.png`);
} finally {
  await chrome.close();
}
