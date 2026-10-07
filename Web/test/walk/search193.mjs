// The #193 walk: the page's sidebar search, as the window's since #176.
// Pairs, types a search a key at a time and reads the sidebar between keys and after the pause,
// shows all of a fold's matches, and asks for More matches….
//
//   node Web/test/walk/search193.mjs <WEB_URL> <browser code> <out dir> [words]
//
// Expects a root seeded with project alpha (hundreds of archived agents named "Seeded archived
// agent N" and a few live) and project beta (a few dozen archived).

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, words = "seeded ar"] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const chrome = await launch({ profile: `/tmp/193-search-chrome-${process.pid}` });
const js = JSON.stringify;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 2`, 20_000);
  await sleep(800);

  const state = () => page.eval(`(() => {
    const folds = [...document.querySelectorAll(".sidebar .project-fold")].map((f) => {
      const archived = f.querySelector("details.archived");
      return {
        project: f.getAttribute("aria-label"),
        archivedCount: archived?.querySelector("summary .count")?.textContent ?? null,
        archivedRows: archived ? archived.querySelectorAll(".nav-item").length : 0,
        showAll: archived?.querySelector(".show-all")?.textContent ?? null,
      };
    });
    return {
      activity: !!document.querySelector(".sidebar .activity"),
      folds,
      more: !!document.querySelector(".sidebar .more-matches"),
    };
  })()`);

  // A key every 100 ms: under the pause, so nothing is filtered until the typing stops.
  await page.focus(".sidebar input.search");
  const between = [];
  for (const key of words) {
    await page.type(key);
    await sleep(100);
    between.push((await state()).activity);
  }
  say(`between keys, Activity still shown (no filtering yet): ${js(between)}`);
  await page.waitFor(`!document.querySelector(".sidebar .activity")`, 5_000);
  await page.waitFor(`document.querySelector(".sidebar .show-all")`, 10_000);
  await sleep(500);
  say(`after the pause: ${js(await state())}`);
  await page.shot(`${out}/193-search-capped.png`);

  await page.eval(`document.querySelector(".sidebar .show-all").click()`);
  await sleep(300);
  say(`Show all on the first fold: ${js((await state()).folds)}`);
  await page.shot(`${out}/193-search-show-all.png`);

  if ((await state()).more) {
    await page.press("More matches…");
    await sleep(1500);
    say(`after More matches…: ${js(await state())}`);
    await page.shot(`${out}/193-search-more.png`);
  }

  // The search ends: the Activity rows are back and the folds are as they were.
  await page.eval(`(() => {
    const field = document.querySelector(".sidebar input.search");
    field.value = "";
    field.dispatchEvent(new Event("input", { bubbles: true }));
  })()`);
  await page.waitFor(`document.querySelector(".sidebar .activity")`, 5_000);
  await sleep(500);
  say(`search cleared: ${js(await state())}`);
} finally {
  writeFileSync(`${out}/193-notes.txt`, notes.join("\n") + "\n");
  await chrome.close();
}
