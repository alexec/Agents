// The #3678 walk: on a scratch control plane whose host reads a fake GitHub (AGENTS_TEST_GITHUB_URL,
// serving anthropics/skills with personas/reviewer.md, never the real one) and keeps ~/.agents in its
// root (AGENTS_PERSONAL_HOME), add a persona in Settings ▸ Agent Configuration ▸ Personas, see it
// marked update as the source moves on, read the update's warning and diff, update, and remove it.
//
//   node Web/test/walk/personas3678.mjs <WEB_URL> <browser code> <out dir> <moved flag file>

import { writeFileSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [webURL, code, out, movedFlag] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const body = (page) => page.text("body").then((t) => t.replace(/\s+/g, " "));
const section = `section[aria-label="Personas"]`;
const has = (selector, text) => `document.querySelector(${JSON.stringify(selector)})?.textContent.includes(${JSON.stringify(text)})`;

const chrome = await launch({ profile: `/tmp/p3678-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(has(section, "Add persona…"), 20_000);
  await page.eval(`document.querySelector('${section}').scrollIntoView()`);
  check(!(await page.eval(has(section, "From a marketplace"))), "none added yet: no heading, only Add persona…");
  await page.shot(`${out}/web-personas-empty.png`);

  await page.press("Add persona…");
  await page.waitFor(`document.querySelector(".persona-result")`, 15_000);
  check(await page.eval(has("dialog", "Adds to ~/.agents")), "the sheet says where it adds");
  await page.shot(`${out}/web-add-search.png`);

  await page.eval(`document.querySelector(".persona-result").click()`);
  await page.waitFor(has("dialog", "Permission mode"), 15_000);
  const preview = await page.text("dialog");
  check(/codex/.test(preview) && /read-only/.test(preview) && /gpt-5/.test(preview), "the preview has the settings it sets");
  check(/name: Reviewer/.test(preview), "the preview has the whole file, front matter included");
  await page.shot(`${out}/web-add-preview.png`);

  // The source moves on now: the host asks GitHub for updates once an hour per repository, so the
  // first ask, just after Add, already sees the new commit.
  writeFileSync(movedFlag, "");
  await page.eval(`document.querySelector("dialog .sheet-actions button.prominent").click()`);
  await page.waitFor(`!document.querySelector("dialog .persona-preview")`, 10_000);
  await page.eval(`[...document.querySelectorAll("dialog .sheet-actions button")].find((b) => b.textContent === "Cancel").click()`);
  await page.waitFor(has(section, "From a marketplace"), 10_000);
  check(await page.eval(has(section, "anthropics/skills")), "the added persona is listed with its source");
  await page.waitFor(has(section, "Update…"), 15_000).catch(() => undefined);
  const marked = await page.eval(has(section, "Update…"));
  check(marked, "the moved source shows update and Update…");
  if (marked) {
    await page.eval(`document.querySelector('${section}').scrollIntoView()`);
    await page.shot(`${out}/web-personas-update.png`);
    await page.press("Update…");
    await page.waitFor(has("dialog", "permission mode"), 15_000);
    const sheet = await page.text("dialog");
    check(/permission mode from read-only to bypass/.test(sheet), "the permission-mode warning, old and new");
    check(/runtime from codex to claude/.test(sheet), "the runtime warning, old and new");
    check(await page.eval(`!!document.querySelector("dialog .file-diff")`), "a diff of the file");
    await page.shot(`${out}/web-update-sheet.png`);
    await page.eval(`document.querySelector("dialog .sheet-actions button.prominent").click()`);
    await page.waitFor(`!document.querySelector("dialog")?.open`, 10_000);
    await page.waitFor(`!(${has(section, "Update…")})`, 10_000);
    check(true, "after Update the mark goes");
    await page.eval(`document.querySelector('${section}').scrollIntoView()`);
    await page.shot(`${out}/web-personas-added.png`);
  }

  await page.eval(`window.confirm = (m) => { window.asked = m; return true; }`);
  await page.eval(`[...document.querySelectorAll('${section} .persona-catalog-row button')].find((b) => b.textContent === "Remove…").click()`);
  const asked = await page.eval(`window.asked`);
  check(/^Move reviewer\.md to the Trash\?/.test(asked ?? ""), `Remove… asks first (${asked})`);
  await page.waitFor(`!(${has(section, "From a marketplace")})`, 10_000);
  check(true, "removed: the list is empty again");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await body(page).catch(() => "")).slice(0, 2000));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
