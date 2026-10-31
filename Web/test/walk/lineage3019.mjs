// A session's Lineage tab (#2940) as a graph (#3019): on a run-app root with sessions linked by
// lineage/link, open a session, choose Lineage, and shoot the graph; then a session with no links.
// Screenshots into <out dir>.
//
//   node Web/test/walk/lineage3019.mjs <WEB_URL> <browser code> <out dir> <linked title> <unlinked title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, linked, unlinked] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-lin3019-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const open = async (title) => {
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.session")].some((r) => r.textContent.includes(${JSON.stringify(title)}))`, 30_000);
  await page.eval(`(() => { const r = [...document.querySelectorAll(".sidebar .row.session")].find((r) => r.textContent.includes(${JSON.stringify(title)})); (r?.querySelector(".pick") ?? r)?.click(); })()`);
  await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
};

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  // The page opens on the Overview (#2141); the sessions are in Agents.
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`[...document.querySelectorAll(".sidebar .pick")].some((b) => b.textContent.trim() === "work")`, 30_000);
  // The folder's sessions, unfolded.
  await page.eval(`[...document.querySelectorAll(".sidebar .pick")].find((b) => b.textContent.trim() === "work")?.parentElement?.querySelector(".disclosure")?.click()`);
  await open(linked);
  await page.press("Files");
  await page.waitFor(`document.querySelector("aside.files")`, 30_000);
  await page.eval(`[...document.querySelectorAll("aside.files [role=tab]")].find((t) => t.textContent === "Lineage")?.click()`);
  await page.waitFor(`[...document.querySelectorAll(".lineage-graph .lineage-box .detail")].some((d) => d.textContent.includes("·"))`, 30_000);
  const boxes = await page.eval(`document.querySelectorAll(".lineage-graph .lineage-box").length`);
  const edges = await page.eval(`document.querySelectorAll(".lineage-graph .lineage-edge").length`);
  ok(`graph ${boxes} boxes, ${edges} lines`, boxes >= 2 && edges >= boxes - 1);
  const here = await page.eval(`document.querySelector(".lineage-box .box.here")?.parentElement.querySelector(".name").textContent`);
  ok(`this session is a box: ${here}`, here === "This session");
  await sleep(400);
  await page.shot(`${out}/web-graph.png`);
  await open(unlinked);
  // Another session shuts the files pane, and its tab is kept per session, as the window's pane is.
  await page.press("Files").catch(() => {});
  await page.eval(`[...document.querySelectorAll("aside.files [role=tab]")].find((t) => t.textContent === "Lineage")?.click()`);
  await page.waitFor(`document.querySelector(".lineage .hint")`, 30_000).catch(async (e) => { await page.shot(`${out}/debug.png`); throw e; });
  ok("no links says so", (await page.eval(`document.querySelector(".lineage .hint").textContent`)).startsWith("No links yet"));
  await sleep(400);
  await page.shot(`${out}/web-empty.png`);
} finally {
  await chrome.close();
}
