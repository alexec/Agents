// Docs by project (#3408), on a run-app root with three folders: shop-app and shop-site in one
// project, notes in a project of its own. The list has a Project filter, All projects first; the
// project's two folders are one source, said by its name; picking a project leaves the other out;
// a doc's page says its project first. Screenshots into <out dir>.
//
//   node Web/test/walk/docs3408.mjs <WEB_URL> <browser code> <out dir>

import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-docs3408-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const shot = async (name) => { await scrub(); await page.shot(`${out}/${name}.png`); };
const pick = (label, value) => page.eval(`(() => {
  const s = [...document.querySelectorAll(".docs-list label")].find((l) => l.textContent.startsWith(${JSON.stringify(label)}))?.querySelector("select");
  const o = [...s.options].find((o) => o.textContent === ${JSON.stringify(value)});
  s.value = o.value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/docs"`);
  await page.waitFor(`document.querySelectorAll(".docs-source").length >= 2`, 30_000);
  await sleep(1500);

  const heads = await text(".docs-source-head");
  ok(`one source per project: ${heads.join(" | ")}`, heads.length === 2 && heads.includes("shop-app") && heads.includes("notes"));
  const projects = await text(".docs-list label:first-of-type option");
  ok(`the Project filter, All projects first: ${projects.join(" | ")}`, projects[0] === "All projects");
  const rows = await text(".docs-source[aria-label='shop-app'] .docs-row");
  ok(`the project's source has both folders' docs: ${rows.length}`, rows.length === 5);
  await shot("web-all");

  await pick("Project", "shop-app");
  await sleep(500);
  const one = await text(".docs-source-head");
  ok(`one project: ${one.join(" | ")}`, one.length === 1 && one[0] === "shop-app");
  await shot("web-project");

  await page.eval(`[...document.querySelectorAll(".docs-row")].find((b) => b.textContent.includes("deploy.md")).click()`);
  await page.waitFor(`document.querySelector(".docs-page .docs-text")`, 30_000);
  await sleep(1000);
  const meta = await text(".docs-page .work-page-head p.quiet");
  ok(`the page says its project first: ${meta[0]}`, meta[0]?.startsWith("shop-app · "));
  await shot("web-doc");
} finally {
  await chrome.close();
}
