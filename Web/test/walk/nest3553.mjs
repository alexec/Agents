// The #3553 walk: sessions under the session that started them at every depth. Unfolds the
// folder's Sessions, then each parent's fold in turn, and shoots the sidebar once the lead is
// open and once every level is.
//
//   node Web/test/walk/nest3553.mjs <WEB_URL> <browser code> <folder name> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folder, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-nest3553-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(3000);
  for (const name of [folder, "Sessions"]) {
    await page.eval(`document.querySelector('[aria-label="Unfold ${name}"]')?.click()`);
    await sleep(1200);
  }
  const unfold = `(() => { const b = document.querySelector('.fold-count[aria-expanded="false"]'); b?.click(); return !!b; })()`;
  await page.eval(unfold);
  await sleep(800);
  await page.shot(`${out}/web-lead-open.png`);
  while (await page.eval(unfold)) await sleep(800);
  console.log("rows:", await page.eval(`[...document.querySelectorAll(".nav-item")].map((e) => (e.style.getPropertyValue("--indent") || "0") + " " + e.innerText.split("\\n")[0]).join(" / ")`));
  await page.shot(`${out}/web-all-open.png`);
} finally {
  await chrome.close();
}
