// The For Review smart group on the page (#3194): a finished session with a file to see is
// listed there, not in Unread; opened, it stays there, read, until another is opened; and its
// switch is in Settings ▸ Sidebar.
//
//   node Web/test/walk/forreview3194.mjs <WEB_URL> <browser code> <out dir>
//
// The root is a run-app scratch root with a folder holding a finished, unread session titled
// "Draft the release notes" whose agent showed a file nobody has looked at.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/fr3194-chrome-${process.pid}` });
const group = (title) => `[...document.querySelectorAll("details, section")]
  .filter((el) => (el.querySelector("summary, h2")?.textContent ?? "").startsWith(${JSON.stringify(title)}))
  .map((el) => el.innerText.replace(/\\s+/g, " ").slice(0, 200))`;
try {
  const page = await chrome.page(webURL, { width: 1300, height: 820 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`document.querySelector('button.disclosure[aria-label="Unfold demo"]')`, 30_000);
  await page.eval(`document.querySelector('button.disclosure[aria-label="Unfold demo"]')?.click()`);
  await sleep(1500);
  console.log("for review", JSON.stringify(await page.eval(group("For Review"))));
  console.log("unread", JSON.stringify(await page.eval(group("Unread"))));
  await page.shot(`${out}/web-for-review.png`);

  await page.eval(`[...document.querySelectorAll("a, [role=button], .row")].find((el) => el.textContent.includes("Draft the release notes"))?.click()`);
  await sleep(2000);
  console.log("opened", JSON.stringify(await page.eval(group("For Review"))));
  await page.shot(`${out}/web-opened.png`);

  await page.eval(`location.hash = "#/settings"`);
  await sleep(800);
  console.log("switches", JSON.stringify(await page.eval(`[...document.querySelectorAll("#settings-sidebar ~ label.setting")]
    .map((l) => l.textContent.trim() + ":" + l.querySelector("input").checked)`)));
  await page.eval(`document.querySelector("#settings-sidebar")?.scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-settings.png`);
} finally {
  await chrome.close();
}
