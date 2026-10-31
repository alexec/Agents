// The #2669 walk, on a scratch root with a folder added: the folder's Connectors page says
// Tasks, Code review and CI are the project's, Use for the Whole Project makes Code review the
// project's ("Set by the project …", its Skip gone), and Use Each Folder's Own gives it back.
// Screenshots go to <out dir>.
//
//   node Web/test/walk/projects2669.mjs <WEB_URL> <browser code> <folder name> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, folderName, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
const card = `document.querySelector(".project-slots")`;
const row = (kind) => `[...document.querySelectorAll(".project-slots .project-slot")].find((p) => p.textContent.includes(${JSON.stringify(kind)}))`;

const chrome = await launch({ profile: `/tmp/projects2669-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(has(folderName), 20_000);
  await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent("file://" +
    document.querySelector('button[data-fold=folder]').title + "/") + "/m/1"`);
  await page.waitFor(`${card} && ${card}.querySelector("button")`, 20_000);
  check(await page.eval(`${card}.textContent.includes("are the project's")`), "the card says whose the slots are");
  await page.shot(`${out}/2669-web-1-card.png`);

  await page.eval(`${row("Code review")}.querySelector("button").click()`);
  await page.waitFor(`${row("Code review")}.textContent.includes("for every folder")`, 10_000).catch(() => {});
  check(await page.eval(`${row("Code review")}.textContent.includes("for every folder")`), "Code review is the project's");
  const slotText = await page.eval(`[...document.querySelectorAll(".slot")].find((s) => s.textContent.includes("pull requests")).textContent`);
  check(slotText.includes("Set by the project") && !slotText.includes("Skip"), `its slot: ${slotText.replace(/\s+/g, " ")}`);
  await page.shot(`${out}/2669-web-2-project.png`);

  await page.eval(`${row("Code review")}.querySelector("button").click()`);
  await page.waitFor(`${row("Code review")}.textContent.includes("this folder's own")`, 10_000).catch(() => {});
  check(await page.eval(`${row("Code review")}.textContent.includes("this folder's own")`), "given back to each folder");
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
