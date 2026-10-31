// The #2317 walk, on a scratch root with folders added: the folder menu's Project… opens the
// project modal, which names the folder's project; New Project… makes one and puts the folder
// in it; Rename Project… renames it. Screenshots go to <out dir>.
//
//   node Web/test/walk/projects2317.mjs <WEB_URL> <browser code> <folder name> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const js = JSON.stringify;

const chrome = await launch({ profile: `/tmp/projects2317-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.folder .pick")].some((e) => e.innerText.startsWith(${js(folderName)}))`, 20_000);

  const openMenu = async () => {
    await page.eval(`(() => {
      const b = [...document.querySelectorAll(".sidebar .row.folder .pick")].find((e) => e.innerText.startsWith(${js(folderName)}));
      const box = b.getBoundingClientRect();
      b.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 10 }));
    })()`);
    await sleep(200);
  };
  await openMenu();
  const items = await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].map((b) => b.textContent)`);
  check(items.includes("Project…"), `folder menu: ${js(items)}`);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "Project…").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet[open] select")`);
  await sleep(500);
  const selected = () => page.eval(`(() => { const s = document.querySelector("dialog.sheet select"); return s.options[s.selectedIndex].text; })()`);
  const options = () => page.eval(`[...document.querySelectorAll("dialog.sheet select option")].map((o) => o.text)`);
  say(`project: ${await selected()} of ${js(await options())}`);
  check(!(await selected()).startsWith("Not on"), "the folder's project is known");
  await page.shot(`${out}/projects-1-modal.png`);

  // New Project…: typed, saved, and the folder is in it.
  await page.press("New Project…");
  await page.waitFor(`document.querySelector("dialog.sheet input[type=text]")`);
  await page.eval(`(() => { const f = document.querySelector("dialog.sheet input[type=text]"); f.value = ""; f.focus(); f.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.type("Walked project");
  await page.shot(`${out}/projects-2-new.png`);
  await page.press("Save");
  await page.waitFor(`(() => { const s = document.querySelector("dialog.sheet select"); return s && s.options[s.selectedIndex].text === "Walked project"; })()`, 10_000).catch(() => {});
  check((await selected()) === "Walked project", `after New Project…: ${await selected()} of ${js(await options())}`);
  await page.shot(`${out}/projects-3-made.png`);

  // Rename Project…
  await page.press("Rename Project…");
  await page.waitFor(`document.querySelector("dialog.sheet input[type=text]")`);
  await page.eval(`(() => { const f = document.querySelector("dialog.sheet input[type=text]"); f.value = ""; f.focus(); f.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.type("Walked again");
  await page.press("Save");
  await page.waitFor(`[...document.querySelectorAll("dialog.sheet select option")].some((o) => o.text === "Walked again")`, 10_000).catch(() => {});
  check((await selected()) === "Walked again", `after Rename Project…: ${await selected()}`);

  // Back to the first project, by the select.
  const first = (await options()).find((o) => o !== "Walked again");
  await page.eval(`(() => { const s = document.querySelector("dialog.sheet select"); s.value = [...s.options].find((o) => o.text === ${js(first)}).value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`(() => { const s = document.querySelector("dialog.sheet select"); return s.options[s.selectedIndex].text === ${js(first)}; })()`, 10_000).catch(() => {});
  check((await selected()) === first, `picked ${first}: ${await selected()}`);
  await page.shot(`${out}/projects-4-picked.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
