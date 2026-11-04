// Work's Project filter (#3283): on a run-app root with two folders in two projects, whose repos are
// the fixture GitHub's example/shop and example/www (forge3283-github.py, AGENTS_TEST_GITHUB_URL), open
// Work ▸ Issues (All projects: both repos' rows), pick the project www (its row only), open that row's
// page (it says its project), and Pull requests with the project shop. Screenshots into <out dir>.
//
//   node Web/test/walk/work3283.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/w3283-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const rows = () => page.eval(`[...document.querySelectorAll(".work-row .work-title")].map((t) => t.textContent)`);
// Pick an option of the filter labelled `label` by its words, as a person does.
const pick = (label, words) => page.eval(`(() => {
  const select = [...document.querySelectorAll(".work-filters label")].find((l) => l.firstChild?.textContent.trim() === ${JSON.stringify(label)})?.querySelector("select");
  const option = [...select?.options ?? []].find((o) => o.textContent === ${JSON.stringify(words)});
  if (!option) return false;
  select.value = option.value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
})()`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 3`, 30_000);
  await sleep(500);
  ok(`All projects lists both repos' issues: ${await rows()}`, (await rows()).length === 3);
  await page.shot(`${out}/web-all-projects.png`);

  ok("the Project filter has www", await pick("Project", "www"));
  await page.waitFor(`document.querySelectorAll(".work-row").length === 1`, 10_000);
  await sleep(300);
  ok(`www lists its issue alone: ${await rows()}`, (await rows())[0] === "The pricing page says the old plans");
  await page.shot(`${out}/web-one-project.png`);

  await page.eval(`document.querySelector(".work-row").click()`);
  await page.waitFor(`document.querySelector(".work-page-head")?.textContent.includes("Project www")`, 30_000);
  await sleep(500);
  ok("the issue's page says its project", true);
  await page.shot(`${out}/web-issue-page.png`);

  await page.eval(`location.hash = "#/work/pr"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 2`, 30_000);
  ok("the Project filter has shop on Pull requests", await pick("Project", "shop"));
  await page.waitFor(`document.querySelectorAll(".work-row").length === 1`, 10_000);
  await sleep(300);
  ok(`shop lists its pull request alone: ${await rows()}`, (await rows())[0] === "Keep the cart in local storage");
  await page.shot(`${out}/web-pull-requests.png`);
} catch (e) {
  console.log(`FAIL ${e.message}`);
  process.exitCode = 1;
} finally {
  await chrome.close();
}
