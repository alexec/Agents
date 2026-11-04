// The #3448 walk, on a scratch root with two folders in one project, the first a Git repository
// whose .gitignore leaves out .agents/worktrees/, .agents/*.local.json and .agents/cache/: Project
// Settings ▸ General has Remove… (Remove from Project) on each folder, and the second leaves the project;
// the first's Folder Settings ▸ Not Committed lists what Git ignores in its .agents. Screenshots
// go to <out dir>.
//
//   node Web/test/walk/folderSettings3448.mjs <WEB_URL> <browser code> <folder name> <out dir> [profile]

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out, profile] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const js = JSON.stringify;

const chrome = await launch({ profile: profile ?? `/tmp/folderSettings3448-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.viewport(1300, 860);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll("a, button")].some((e) => e.textContent.trim() === "Agents")`, 20_000);
  await page.eval(`[...document.querySelectorAll("a, button")].find((e) => e.textContent.trim() === "Agents").click()`);
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.folder .pick")].some((e) => e.innerText.startsWith(${js(folderName)}))`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .pick")].find((e) => e.innerText.startsWith(${js(folderName)}));
    const box = b.getBoundingClientRect();
    b.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 10 }));
  })()`);
  await sleep(300);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "Project Settings…").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet[open] .settings-sheet")`);
  await sleep(1200);
  const rows = `document.querySelectorAll("dialog.sheet[open] .project-folders li")`;
  const removes = await page.eval(`[...document.querySelectorAll("dialog.sheet[open] .project-folders button")].filter((b) => b.textContent === "Remove…").length`);
  check(removes === 2, `Remove… on each folder: ${removes}`);
  await page.shot(`${out}/web-project-general.png`);
  // A headless page draws no confirm(), so it is answered here, and what it asked is kept.
  await page.eval(`window.confirm = (m) => { window.asked = m; return true; }`);
  // The other folder leaves: the one the dialog was opened on stays, with the project.
  await page.eval(`[...[...document.querySelectorAll("dialog.sheet[open] .project-folders li")]
    .find((li) => !li.querySelector(".path").textContent.endsWith("/" + ${js(folderName)})).querySelectorAll("button")]
    .find((b) => b.textContent === "Remove…").click()`);
  await page.waitFor(`${rows}.length === 1`, 10_000);
  const asked = await page.eval(`window.asked`);
  check(/^Remove .* from this project\?\n\nIt gets a project of its own, named after it\./.test(asked ?? ""), `it asked: ${js(asked)}`);
  await sleep(600);
  const left = await page.eval(`${rows}.length`);
  check(left === 1, `the project's folders after: ${left}`);
  await page.shot(`${out}/web-project-removed.png`);
  await page.eval(`[...document.querySelectorAll("dialog.sheet[open] .project-folders button")].find((b) => b.textContent === "Folder Settings…").click()`);
  await page.waitFor(`[...document.querySelectorAll("dialog.sheet[open] h2")].some((h) => h.textContent.startsWith("Folder Settings"))`);
  await page.eval(`[...document.querySelectorAll("dialog.sheet[open] [role=tab]")].find((b) => b.textContent === "Not Committed").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet[open] .not-committed-paths")`, 10_000);
  const paths = await page.eval(`[...document.querySelectorAll("dialog.sheet[open] .not-committed-paths code")].map((c) => c.textContent)`);
  check(js(paths) === js([".agents/cache/", ".agents/settings.local.json", ".agents/worktrees/"]), `not committed: ${js(paths)}`);
  await page.shot(`${out}/web-folder-not-committed.png`);
} finally {
  await chrome.close();
}
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
