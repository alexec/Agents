// A lead's sidebar row (#3270): on a run-app root whose folder is on the fixture GitHub
// (forge3268-github.py, AGENTS_TEST_GITHUB_URL) with a session labelled #40 and lead, see the
// lead's row say the epic's progress after its title. A screenshot into <out dir>.
//
//   node Web/test/walk/lead3270.mjs <WEB_URL> <browser code> <out dir> [expected, 2/5]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, expected = "2/5"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-lead3270-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  // Unfold the folder when it is folded, so the lead's row is drawn.
  await page.waitFor(`document.querySelector(".lead-progress") || document.querySelector('button.disclosure[aria-label="Unfold shop"]')`, 30_000);
  await page.eval(`document.querySelector(".lead-progress") || document.querySelector('button.disclosure[aria-label="Unfold shop"]')?.click()`);
  await page.waitFor(`document.querySelector(".lead-progress")`, 30_000).catch(() => {});
  const said = await page.eval(`document.querySelector(".lead-progress")?.textContent.trim() ?? ""`);
  ok(`the lead's row says ${said}`, said === `· ${expected}`);
  const spoken = await page.eval(`document.querySelector(".lead-progress")?.getAttribute("aria-label") ?? ""`);
  ok(`a screen reader hears ${spoken}`, spoken.endsWith("done"));
  await sleep(800);
  await page.shot(`${out}/web-lead.png`);
} finally {
  await chrome.close();
}
