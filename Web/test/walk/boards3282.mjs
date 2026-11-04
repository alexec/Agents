// Boards (#3282): on a run-app root whose folder's project has boards, see them on the folder's
// Connectors page, add a board whose address names none and see why, then choose a board in
// Work ▸ Issues and Work ▸ Features. Screenshots into <out dir>.
//
//   node Web/test/walk/boards3282.mjs <WEB_URL> <browser code> <folder path> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folder, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-brd3282-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 860 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const has = (s) => `document.body.textContent.includes(${JSON.stringify(s)})`;
// A select by its label's words, set as a person picks it.
const choose = (label, words) => page.eval(`(() => {
  const select = [...document.querySelectorAll("label")].find((l) => l.textContent.trim().startsWith(${JSON.stringify(label)}))?.querySelector("select");
  const option = [...(select?.options ?? [])].find((o) => o.textContent === ${JSON.stringify(words)});
  if (!option) return false;
  select.value = option.value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
})()`);
// A field by its placeholder, typed as a person types.
const fill = async (placeholder, text) => {
  await page.focus(`input[placeholder=${JSON.stringify(placeholder)}]`);
  await page.eval(`document.activeElement.select()`);
  await page.type(text);
};

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(has("Overview"), 30_000);

  // The folder's Connectors page, by its address.
  await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent(${JSON.stringify(`file://${folder}/`)}) + "/m/1"`);
  await page.waitFor(`document.querySelector(".project-boards li")`, 30_000);
  ok("the project's boards are listed", await page.eval(has("Web team")) && await page.eval(has("Linear team")));
  await page.eval(`document.querySelector(".project-boards").scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/${prefix}-boards.png`);

  await fill("Name", "Ops");
  await fill("https://github.com/orgs/acme/projects/7", "https://github.com/acme/shop");
  await page.press("Add Board");
  await page.waitFor(`document.querySelector(".project-boards .failure")`, 10_000);
  ok("an address that names no board is refused, with why", await page.eval(has("is not the address of a GitHub Projects board")));
  await page.eval(`document.querySelector(".project-boards").scrollIntoView({ block: "center" })`);
  await sleep(300);
  await page.shot(`${out}/${prefix}-error.png`);

  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`[...document.querySelectorAll("label")].some((l) => l.textContent.trim().startsWith("Board"))`, 30_000);
  ok("Issues has a Board menu", await choose("Board", "Web team"));
  await sleep(1500);
  await page.shot(`${out}/${prefix}-work-board.png`);

  await page.eval(`location.hash = "#/work/features"`);
  await page.waitFor(`[...document.querySelectorAll("label")].some((l) => l.textContent.trim().startsWith("Board"))`, 30_000);
  ok("Features has a Board menu", await choose("Board", "Platform"));
  await sleep(1500);
  await page.shot(`${out}/${prefix}-features-board.png`);
} finally {
  await chrome.close();
}
