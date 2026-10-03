// The Files tree walk (#133): on a run-app root with a deep repo `work` and one session in it,
// expand three levels, open a file, go Back, shut a sibling, open and go Back again; the keys;
// a folder of thousands; and the phone's one-folder list. Screenshots and notes into <out dir>.
//
//   node Web/test/walk/filestree.mjs <WEB_URL> <browser code> <out dir> <session title>

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, title] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const chrome = await launch({ profile: `/tmp/133-tree-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
const shot = async (name) => { await sleep(400); await page.shot(`${out}/${name}.png`); say(`shot ${name}.png`); };
const ok = (what, cond) => { say(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".projects .row")`, 30_000);
  await page.eval(`[...document.querySelectorAll(".projects .row")].find((r) => r.textContent.includes("work"))?.click()`);
  await page.waitFor(`document.querySelector(".sessions .row.session")`, 30_000);
  await page.eval(`(() => { const r = [...document.querySelectorAll(".sessions .row.session")].find((r) => r.textContent.includes(${JSON.stringify(title)})); (r?.querySelector(".pick") ?? r)?.click(); })()`);
  await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
  await page.press("Files");
  await page.waitFor(`document.querySelector("aside.files [role=tree] [role=treeitem]")`, 30_000);

  const rows = () => page.eval(`[...document.querySelectorAll("aside.files [role=treeitem]")].map((r) => ({
    label: r.getAttribute("aria-label"), level: +r.getAttribute("aria-level"), expanded: r.getAttribute("aria-expanded"),
    marked: r.classList.contains("chosen"), cursor: r.classList.contains("cursor") }))`);
  const row = (name) => `[...document.querySelectorAll("aside.files [role=treeitem]")].find((r) => r.getAttribute("aria-label").split(",")[0] === ${JSON.stringify(name)})`;
  const click = async (name) => {
    if (!(await page.eval(`(() => { const r = ${row(name)}; r?.click(); return !!r; })()`))) throw new Error(`no row ${name}`);
    await sleep(500);
  };
  const back = async () => { await page.eval(`document.querySelector("aside.files .crumbs button")?.click()`); await sleep(600); };
  const key = async (k) => {
    const code = { ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Enter: 13 }[k];
    for (const type of ["keyDown", "keyUp"]) await page.raw("Input.dispatchKeyEvent", { type, key: k, code: k, windowsVirtualKeyCode: code });
    await sleep(300);
  };
  const expanded = async (name) => (await page.eval(`${row(name)}?.getAttribute("aria-expanded")`)) === "true";

  await shot("tree-top");
  say(`top: ${JSON.stringify((await rows()).map((r) => r.label))}`);

  // Three levels down, and a sibling open beside them.
  await click("Sources"); await click("App"); await click("Core"); await click("Docs");
  ok("three levels open", (await expanded("Sources")) && (await expanded("App")) && (await expanded("Core")));
  say(`open: ${JSON.stringify((await rows()).filter((r) => r.level <= 4).map((r) => `${r.level}:${r.label}`))}`);
  await shot("tree-three-levels");

  await click("Engine.swift");
  await page.waitFor(`document.querySelector("aside.files .file-text")`, 10_000);
  await shot("tree-file-open");
  await back();
  ok("Back: Engine.swift marked", (await rows()).find((r) => r.label.startsWith("Engine.swift"))?.marked === true);
  ok("Back: Core still open", await expanded("Core"));
  await shot("tree-back");

  // Shut the sibling, open another file, go Back: the three levels stay, the sibling stays shut.
  await click("Docs");
  ok("Docs shut", !(await expanded("Docs")));
  await click("README.md");
  await back();
  ok("Back again: Sources/App/Core open, Docs shut",
    (await expanded("Sources")) && (await expanded("App")) && (await expanded("Core")) && !(await expanded("Docs")));
  ok("Back again: README.md marked", (await rows()).find((r) => r.label.startsWith("README.md"))?.marked === true);
  await click("Engine.swift");
  await back();
  ok("Engine.swift marked again", (await rows()).find((r) => r.label.startsWith("Engine.swift"))?.marked === true);
  await shot("tree-sibling-shut-back");

  // The keys.
  await page.focus("aside.files [role=tree]");
  const cursor = async () => (await rows()).find((r) => r.cursor)?.label;
  await key("ArrowUp");
  say(`up from Engine.swift: ${await cursor()}`);
  await key("ArrowLeft");
  say(`left: ${await cursor()}`);
  await key("ArrowLeft");
  ok("left shuts the folder the cursor is on", !(await expanded("Core")));
  await key("ArrowRight");
  ok("right opens it again", await expanded("Core"));
  await key("ArrowDown"); await key("ArrowDown");
  const onto = await cursor();
  await key("Enter");
  await sleep(500);
  ok(`Return opens ${onto}`, await page.eval(`!!document.querySelector("aside.files .file .crumbs")`));
  await back();
  await shot("tree-keys");

  // A folder of thousands: only the rows in view are drawn.
  await click("Many");
  await page.waitFor(`${row("file-0001.txt")}`, 20_000);
  const drawn = await page.eval(`document.querySelectorAll("aside.files .file-tree > li").length`);
  const height = await page.eval(`document.querySelector("aside.files .file-tree").getBoundingClientRect().height`);
  ok(`a folder of 3000: ${drawn} rows drawn, the list ${height}px tall`, drawn < 120 && height > 3000 * 20);
  await page.eval(`document.querySelector("aside.files .scroll").scrollTop = 40000`);
  await sleep(400);
  say(`scrolled: ${JSON.stringify((await rows()).slice(0, 3).map((r) => r.label))}`);
  await shot("tree-many-scrolled");
  await page.eval(`document.querySelector("aside.files .scroll").scrollTop = 0`);
  await click("Many");

  // The phone keeps the one-folder list.
  await page.viewport(390, 844);
  await sleep(800);
  const list = await page.eval(`!!document.querySelector("aside.files ul.entries") && !document.querySelector("aside.files [role=tree]")`);
  ok("at 390 Files is the one-folder list", list);
  await shot("phone-folder-list");
} catch (e) {
  say(`ERROR ${e.message}`);
  await page.shot(`${out}/error.png`).catch(() => {});
  process.exitCode = 1;
} finally {
  writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
  await chrome.close();
}
