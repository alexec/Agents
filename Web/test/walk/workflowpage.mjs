// The workflow page walk (#142): every attribute read-only, in the window's order, with Run now
// or Approve, Enabled and Archive kept. On a run-app root seeded as specs/142-workflow-page says:
// Nightly review (standing, labels, cooldown, notify:), Close landed issues (enabled: false) and
// Write release notes (new, waiting for its OK). Approve is pressed on the last.
//
//   node Web/test/walk/workflowpage.mjs <WEB_URL> <browser code> <out dir>
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chrome = await launch({ profile: `/tmp/142-workflowpage-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1440, height: 1100 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".project-fold .row.project")`, 30_000);
  const unfold = `document.querySelector(".project-fold .disclosure[aria-expanded=false]")?.click()`;
  await page.eval(unfold);
  await page.waitFor(`document.querySelector(".row.workflow")`, 30_000);
  const visible = (selector) => page.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})]
    .filter((el) => el.offsetParent !== null).map((el) => el.innerText.replace(/\\s+/g, " ").trim())`);
  const parts = ".workflow-page h1, .workflow-page .controls, .workflow-page .status-card li, .workflow-page .agent-mode, "
    + ".workflow-page .settings div, .workflow-page .labels, .workflow-page .unknown-keys code";
  for (const [name, file] of [["Nightly review", "on"], ["Close landed issues", "off-by-file"], ["Write release notes", "awaiting-approval"]]) {
    await page.eval(`[...document.querySelectorAll(".row.workflow")].find((r) => r.querySelector(".title")?.textContent.includes(${JSON.stringify(name)}))?.querySelector(".pick").click()`);
    await page.waitFor(`document.querySelector(".workflow-page h1")?.textContent === ${JSON.stringify(name)}`, 10_000);
    await sleep(400);
    console.log(`${name}: ${JSON.stringify(await visible(parts))}`);
    await page.shot(`${out}/web-${file}.png`);
  }
  await page.press("Approve");
  await page.waitFor(`!document.querySelector(".workflow-page .status-card li.attention")`, 10_000);
  await sleep(300);
  console.log(`approved: ${JSON.stringify(await visible(".workflow-page .controls, .workflow-page .status-card li"))}`);
  await page.shot(`${out}/web-approved.png`);
} finally {
  await chrome.close();
}
