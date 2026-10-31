// The #2671 walk, on a scratch root with one folder added: Add Folder… has a Project menu that starts
// on Its Own Project and lists the organisation's projects; a folder added with one picked is in it;
// Console ▸ Projects lists each project, its owner and its folders, renames one, and keeps Remove off
// while a folder is in it. Screenshots go to <out dir>.
//
//   node Web/test/walk/projects2671.mjs <WEB_URL> <browser code> <first folder name> <second folder path> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, secondPath, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const js = JSON.stringify;

const chrome = await launch({ profile: `/tmp/run-p2671-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.folder .pick")].some((e) => e.innerText.startsWith(${js(folderName)}))`, 20_000);

  // Add Folder…: the Project menu, Its Own Project first.
  await page.eval(`document.querySelector("button[aria-label='New folder']").click()`);
  await sleep(200);
  await page.eval(`[...document.querySelectorAll("[role=menuitem]")].find((b) => b.textContent === "Add Folder…").click()`);
  await page.waitFor(`document.querySelector(".new-folder-project select")`, 10_000);
  const options = await page.eval(`[...document.querySelectorAll(".new-folder-project option")].map((o) => o.text)`);
  check(options[0] === "Its Own Project" && options.includes(folderName), `Project menu: ${js(options)}`);
  await page.eval(`(() => { const f = document.querySelector("dialog.sheet input[aria-label=Folder]"); f.value = ${js(secondPath)};
    f.dispatchEvent(new Event("input", { bubbles: true })); f.form.requestSubmit(); })()`);
  await page.waitFor(`document.querySelector("dialog.sheet input[aria-label=Folder]").value.includes(${js(secondPath)})`, 10_000);
  await page.eval(`(() => { const s = document.querySelector(".new-folder-project select");
    s.value = [...s.options].find((o) => o.text === ${js(folderName)}).value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await sleep(200);
  await page.shot(`${out}/p2671-1-add-folder.png`);
  await page.press("Add as folder");
  const second = secondPath.split("/").pop();
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.folder .pick")].some((e) => e.innerText.startsWith(${js(second)}))`, 20_000);
  check(true, `${second} added`);

  // Console ▸ Projects.
  await page.press("Console");
  await page.waitFor(`[...document.querySelectorAll(".sub-app-row")].some((b) => b.textContent.startsWith("Projects") && !b.disabled)`, 20_000);
  await page.eval(`[...document.querySelectorAll(".sub-app-row")].find((b) => b.textContent.startsWith("Projects")).click()`);
  await page.waitFor(`document.querySelector(".console-projects table")`, 10_000);
  await sleep(500);
  const rows = () => page.eval(`[...document.querySelectorAll(".console-projects tbody tr")].map((r) => [...r.cells].map((c) => c.innerText.replace(/\\s+/g, " ").trim()))`);
  const listed = await rows();
  say(`rows: ${js(listed)}`);
  const row = listed.find((r) => r[0].startsWith(folderName));
  check(row && row[2].includes(folderName) && row[2].includes(second), "both folders in the first folder's project");
  check(row && row[1] && row[1] !== "Nobody", `owner: ${row?.[1]}`);
  const removeOff = await page.eval(`(() => { const r = [...document.querySelectorAll(".console-projects tbody tr")].find((r) => r.cells[0].innerText.startsWith(${js(folderName)}));
    const b = [...r.querySelectorAll("button")].find((b) => b.textContent === "Remove Project"); return b ? [b.disabled, b.title] : null; })()`);
  check(removeOff && removeOff[0] && removeOff[1].includes("Move its folders"), `Remove: ${js(removeOff)}`);
  await page.shot(`${out}/p2671-2-console.png`);

  // Rename…
  await page.eval(`[...[...document.querySelectorAll(".console-projects tbody tr")].find((r) => r.cells[0].innerText.startsWith(${js(folderName)}))
    .querySelectorAll("button")].find((b) => b.textContent === "Rename Project…").click()`);
  await page.waitFor(`document.querySelector(".console-projects input[type=text]")`);
  await page.eval(`(() => { const f = document.querySelector(".console-projects input[type=text]"); f.value = ""; f.focus(); f.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.type("Walked 2671");
  await page.press("Save");
  await page.waitFor(`[...document.querySelectorAll(".console-projects tbody tr")].some((r) => r.cells[0].innerText.startsWith("Walked 2671"))`, 10_000).catch(() => {});
  check((await rows()).some((r) => r[0].startsWith("Walked 2671")), "renamed");
  await page.shot(`${out}/p2671-3-renamed.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
