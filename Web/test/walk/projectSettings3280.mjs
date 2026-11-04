// The #3280 walk, on a scratch root with two folders in one project: the folder menu's Project
// Settings… opens the project's dialog (General with both folders, Tools, Work at Once, Sessions,
// Policy, Agent Configuration); a folder's Folder Settings… there opens that folder's (General,
// Disk Space), and Project Settings… goes back. Screenshots go to <out dir>.
//
//   node Web/test/walk/projectSettings3280.mjs <WEB_URL> <browser code> <folder name> <out dir> [profile]

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out, profile] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const js = JSON.stringify;

const chrome = await launch({ profile: profile ?? `/tmp/projectSettings3280-chrome-${process.pid}` });
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
  const items = await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].map((b) => b.textContent)`);
  check(items.includes("Project Settings…") && items.includes("Folder Settings…"), `folder menu: ${js(items)}`);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "Project Settings…").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet[open] .settings-sheet")`);
  await sleep(1200);
  const folders = await page.eval(`document.querySelectorAll("dialog.sheet[open] .project-folders li").length`);
  check(folders === 2, `the project's folders: ${folders}`);
  const tab = async (name) => {
    await page.eval(`[...document.querySelectorAll("dialog.sheet[open] [role=tab]")].find((b) => b.textContent === ${js(name)}).click()`);
    await sleep(400);
  };
  await page.shot(`${out}/web-project-general.png`);
  for (const [name, file] of [["Work at Once", "work-at-once"], ["Sessions", "sessions"], ["Tools", "tools"]]) {
    await tab(name);
    await page.shot(`${out}/web-project-${file}.png`);
  }
  await tab("General");
  await page.eval(`[...document.querySelectorAll("dialog.sheet[open] .project-folders button")][0].click()`);
  await page.waitFor(`[...document.querySelectorAll("dialog.sheet[open] h2")].some((h) => h.textContent.startsWith("Folder Settings"))`);
  await sleep(400);
  await page.shot(`${out}/web-folder-general.png`);
  await tab("Disk Space");
  await page.shot(`${out}/web-folder-disk-space.png`);
} finally {
  await chrome.close();
}
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
