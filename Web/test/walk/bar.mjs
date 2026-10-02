// The prompt bar's look (#108): a new session and an open session, at 1440 and at phone width, to
// set beside the window's. Reads nothing back but where the bar's controls are.
//
//   node Web/test/walk/bar.mjs <WEB_URL> <browser code> <project name> <session title> <out dir> <prefix>
//
// The code is a browser's (`agents-control code --client --browser`).

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, project, title, out, prefix] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };

const chrome = await launch({ profile: `/tmp/108-bar-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

const clickRow = (text) => page.eval(`(() => {
  const row = [...document.querySelectorAll(".row")].find((r) => r.querySelector(".title")?.textContent === ${JSON.stringify(text)}
    && r.offsetParent !== null);
  row?.click();
  return !!row;
})()`);

/** Each visible control in the bar, with where it sits against the input. */
const where = () => page.eval(`(() => {
  const bar = document.querySelector(".chat .foot");
  const input = bar?.querySelector("textarea");
  if (!input) return [];
  const box = input.getBoundingClientRect();
  return [...bar.querySelectorAll("button, select, input:not([type=file])")].filter((el) => el.offsetParent !== null || el.tagName === "SELECT")
    .map((el) => {
      const r = (el.tagName === "SELECT" ? el.parentElement : el).getBoundingClientRect();
      if (!r.width) return null;
      const name = el.getAttribute("aria-label") ?? el.textContent.trim();
      const row = r.bottom <= box.top + 2 ? "above" : r.top >= box.bottom - 2 ? "below" : "beside";
      return name + ": " + row + " the input, " + (r.left + r.width / 2 < box.left + box.width / 2 ? "left" : "right");
    }).filter(Boolean);
})()`);

const problems = () => page.eval(`(() => {
  const found = [];
  for (const column of document.querySelectorAll(".chat")) {
    if (column.offsetParent === null) continue;
    if (column.scrollWidth > column.clientWidth + 1) found.push("the chat scrolls sideways");
  }
  if (document.documentElement.scrollWidth > innerWidth + 1) found.push("the page scrolls sideways");
  const prompt = document.querySelector(".chat .prompt");
  if (prompt && prompt.offsetParent !== null) {
    const box = prompt.getBoundingClientRect();
    if (box.bottom > innerHeight + 1 || box.top < 0) found.push("the prompt is off-screen");
  }
  return found;
})()`);

async function shoot(name, width, height) {
  await page.viewport(width, height);
  await sleep(400);
  await page.shot(`${out}/${prefix}-${name}.png`);
  say(`${name} (${width}×${height}): ${JSON.stringify(await where())}; problems ${JSON.stringify(await problems())}`);
}

if (!(await clickRow(project))) throw new Error(`no project called ${project}`);
await page.waitFor(`document.querySelector(".sessions .row")`);
await page.press("New session");
await page.waitFor(`document.querySelector(".new-agent .menus") || document.querySelector(".new-agent .failure")`, 60_000);
await shoot("new-1440", 1440, 900);
// The reach chip's folders, where the page has one (#108).
if (await page.eval(`!!document.querySelector(".reach .pill")`)) {
  await page.viewport(1440, 900);
  await page.eval(`document.querySelector(".reach .pill").click()`);
  await sleep(200);
  await page.focus(".reach-popover input");
  await page.type("/tmp");
  await page.press("Add");
  await sleep(200);
  await page.shot(`${out}/${prefix}-new-1440-reach.png`);
  say(`reach: ${JSON.stringify(await page.text(".reach .pill"))}`);
  await page.eval(`document.querySelector(".reach .pill").click()`);
}
await shoot("new-390", 390, 844);

await page.viewport(1440, 900);
await sleep(200);
if (!(await clickRow(title))) throw new Error(`no session called ${title}`);
await page.waitFor(`document.querySelector(".chat .menus")`, 30_000);
await shoot("session-1440", 1440, 900);
await shoot("session-390", 390, 844);

say(`checks: errors ${JSON.stringify(page.errors)}`);
writeFileSync(`${out}/${prefix}-notes.txt`, notes.join("\n") + "\n");
await chrome.close();
