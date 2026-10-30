// The #2352 walk, on a scratch root with a folder added: the folder menu's Cost on Pull
// Requests… opens the modal, which says the folder's setting; a pick goes to the host.
// Screenshots go to <out dir>.
//
//   node Web/test/walk/prcost2352.mjs <WEB_URL> <browser code> <folder name> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const js = JSON.stringify;

const chrome = await launch({ profile: `/tmp/run-c2352-chrome-${process.pid}` });
const page = await chrome.page(webURL);
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.folder .pick")].some((e) => e.innerText.startsWith(${js(folderName)}))`, 20_000);

  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .pick")].find((e) => e.innerText.startsWith(${js(folderName)}));
    const box = b.getBoundingClientRect();
    b.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 10 }));
  })()`);
  await sleep(300);
  const items = await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].map((b) => b.textContent)`);
  check(items.includes("Cost on Pull Requests…"), `folder menu: ${js(items)}`);
  await page.shot(`${out}/web-menu.png`);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "Cost on Pull Requests…").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet[open] select")`);
  await sleep(500);
  const selected = () => page.eval(`(() => { const s = document.querySelector("dialog.sheet select"); return s.options[s.selectedIndex].text; })()`);
  check((await selected()) === "Cost, tokens and time", `shown: ${await selected()}`);
  await page.shot(`${out}/web-cost.png`);

  await page.eval(`(() => { const s = document.querySelector("dialog.sheet select"); s.value = "tokens"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`(() => { const s = document.querySelector("dialog.sheet select"); return s.options[s.selectedIndex].text === "Tokens and time" && !s.disabled; })()`, 10_000).catch(() => {});
  check((await selected()) === "Tokens and time", `picked: ${await selected()}`);
  await page.shot(`${out}/web-tokens.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
