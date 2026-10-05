// The #235 walk: at a phone's width the page's root is the one sidebar, as the iPhone Remote's
// (#226), and what it picks takes its place with ‹ Agents back to it.
//
//   node Web/test/walk/narrow235.mjs <WEB_URL> <browser code> <out dir>
//
// Expects a root with at least one project on this Mac holding a session.

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const chrome = await launch({ profile: `/tmp/235-narrow-chrome-${process.pid}` });
const js = JSON.stringify;

try {
  const page = await chrome.page(webURL, { width: 390, height: 844 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 1`, 20_000);
  await sleep(800);

  const visible = () => page.eval(`["sidebar", "chat", "files"].filter((c) => { const el = document.querySelector("." + c); return el && el.offsetParent !== null; })`);
  const sideways = () => page.eval(`document.documentElement.scrollWidth > innerWidth + 1`);
  const hash = () => page.eval(`location.hash`);
  const back = () => page.eval(`(() => { const b = [...document.querySelectorAll("button.back")].find((e) => e.offsetParent !== null); b?.click(); return b?.textContent ?? null; })()`);
  const at = async (name) => {
    await sleep(500);
    say(`${name}: ${await hash()} · shown ${js(await visible())}${(await sideways()) ? " — scrolls sideways" : ""}`);
    await page.shot(`${out}/${name}.png`);
  };

  // 1: the root is the list, titled Agents, every project folded.
  await page.eval(`localStorage.removeItem("agents.sidebar.folds"); location.hash = "#/"`);
  await at("1-root-list");
  say(`title: ${js(await page.eval(`document.querySelector(".sidebar-head h1")?.innerText`))}`);

  // 2: a project unfolded in place, as the iPhone's row unfolds.
  await page.eval(`document.querySelector(".sidebar .row.project .disclosure").click()`);
  await at("2-unfolded");

  // 3: a session picked takes the list's place; ‹ Agents goes back to it, still unfolded.
  await page.eval(`document.querySelector(".sidebar .row.session")?.click()`);
  await page.waitFor(`document.querySelector(".chat textarea")`, 10_000).catch(() => {});
  await at("3-session");
  say(`back says: ${js(await back())}`);
  await at("4-back-to-list");
  say(`still unfolded: ${await page.eval(`document.querySelector(".sidebar .row.project .pick").getAttribute("aria-expanded")`)}`);

  // 5: the project's row opens its Dashboard; the browser's Back comes back to the list.
  await page.eval(`document.querySelector(".sidebar .row.project .pick").click()`);
  await page.waitFor(`document.querySelector(".dashboard-page")`, 10_000).catch(() => {});
  await at("5-dashboard");
  await page.eval(`history.back()`);
  await at("6-browser-back");

  // 7: an Activity page, and back.
  await page.eval(`document.querySelector(".sidebar .activity-row").click()`);
  await at("7-activity");
  say(`back says: ${js(await back())}`);
  await at("8-back-again");

  // 9: from 760 the sidebar stays beside the chat, with no back control.
  await page.eval(`document.querySelector(".sidebar .row.session")?.click()`);
  await page.viewport(760, 800);
  await at("9-at-760");
  say(`back shown at 760: ${await page.eval(`[...document.querySelectorAll("button.back")].some((e) => e.offsetParent !== null)`)}`);
  const errors = await page.eval(`(window.__errors ?? []).length`).catch(() => 0);
  say(`errors on the page: ${errors}`);
} finally {
  writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
  await chrome.close();
}
