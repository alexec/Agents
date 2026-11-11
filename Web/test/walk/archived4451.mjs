// Archived Sessions and Archived Workflows (#4451), on a run-app root whose folder `work` has 60 archived
// sessions (scripts/seed-archived.swift: some today, yesterday, three days ago, the rest older) and two
// archived workflows: the two sidebar rows (the scratch window approves the browser when it asks); Archived Sessions by day, with 50 of 60 and Load more; the
// filter, with a match and with none; Archived Workflows; both at 390 px. Screenshots into <out dir>.
//
//   node Web/test/walk/archived4451.mjs <WEB_URL> <browser code> <ROOT> <out dir>

import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out] = process.argv.slice(2);
const chrome = await launch({ profile: "/tmp/run-ar4451-chrome" });
const page = await chrome.page(webURL, { width: 1300, height: 860 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const shot = async (name) => { await scrub(); await page.shot(`${out}/${name}.png`); };
const filter = async (words) => {
  await page.eval(`(() => { const i = document.querySelector(".archived-filter"); i.value = ${JSON.stringify(words)};
    i.dispatchEvent(new Event("input", { bubbles: true })); })()`);
};

try {
  // Paired already when the profile was kept from a run before.
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  // A new browser joins the lock once the scratch window approves it (walk.py … press "Compare Digits", then Approve).
  await sleep(2000);
  await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 180_000);
  await page.eval(`location.reload()`);
  await sleep(1500);
  // The folder's rows show once it is unfolded: open it, then its Archived Sessions row.
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`!!document.querySelector(".folder-fold")`, 30_000);
  await page.eval(`document.querySelector(".folder-fold .disclosure[aria-expanded=false]")?.click()`);
  await page.waitFor(`!![...document.querySelectorAll(".row.page-row .title")].find((e) => e.textContent === "Archived Sessions")`, 30_000);
  await page.press("Archived Sessions, 60 archived sessions");
  await page.waitFor(`!!document.querySelector(".archived-page.sessions .archived-footer")`, 30_000);
  await sleep(500);
  const rows = await text(".nav-item .row.page-row .title");
  ok(`two rows after Connectors: ${rows.join(" | ")}`, rows.includes("Archived Sessions") && rows.includes("Archived Workflows"));
  ok("the open page's row is chosen", (await text(".row.page-row.chosen .title")).join() === "Archived Sessions");
  const heads = await text(".archived-page .subhead");
  ok(`day headings: ${heads.join(" | ")}`, heads[0] === "Today" && heads[1] === "Yesterday" && heads.length >= 4);
  const foot = await text(".archived-footer");
  ok(`footer: ${foot}`, /^50 of 60 archived sessions/.test(foot[0] ?? ""));
  await shot("web-sessions");
  await page.eval(`document.querySelector(".archived-page .scroll").scrollTop = 1e6`);
  await shot("web-sessions-load-more");

  await page.press("Load more");
  await page.waitFor(`/^60 archived sessions/.test(document.querySelector(".archived-footer")?.textContent ?? "")`, 15_000);
  ok("Load more: all 60", true);
  await page.eval(`document.querySelector(".archived-page .scroll").scrollTop = 1e6`);
  await shot("web-sessions-all-loaded");
  await page.eval(`document.querySelector(".archived-page .scroll").scrollTop = 0`);

  await filter("simulator");
  await page.waitFor(`document.querySelectorAll(".archived-page .row.session").length === 1`, 5_000);
  ok("the filter keeps the one that matches", true);
  await shot("web-sessions-filter");
  await filter("nothing like this");
  await page.waitFor(`!!document.querySelector(".archived-middle .work-empty")`, 5_000);
  ok(`no match: ${await text(".archived-middle .work-empty")}`, (await text(".archived-middle .work-empty"))[0]?.includes("No archived sessions match"));
  await shot("web-sessions-no-match");
  await page.press("Clear");
  await page.waitFor(`!!document.querySelector(".archived-footer")`, 5_000);

  await page.press("Archived Workflows, 2 archived workflows");
  await page.waitFor(`!!document.querySelector(".archived-page.workflows .archived-footer")`, 10_000);
  ok(`workflows: ${await text(".archived-page.workflows .row.workflow .title")}`, (await text(".archived-page.workflows .row.workflow")).length === 2);
  ok(`its footer: ${await text(".archived-footer")}`, (await text(".archived-footer"))[0] === "2 archived workflows");
  ok("the address", (await page.eval("location.hash")).endsWith("/ar/workflows"));
  await shot("web-workflows");

  await page.viewport(390, 844);
  await sleep(400);
  await shot("web-390-workflows");
  await page.eval(`location.hash = location.hash.replace("/ar/workflows", "/ar/sessions")`);
  await page.waitFor(`!!document.querySelector(".archived-page.sessions .archived-footer")`, 10_000);
  await sleep(400);
  await shot("web-390-sessions");
  // An old link opens sessions.
  void root;
  await page.eval(`location.hash = location.hash.replace("/ar/sessions", "/ar/1")`);
  await sleep(400);
  ok("an old ar/1 opens Archived Sessions", !!(await page.eval(`!!document.querySelector(".archived-page.sessions")`)));
} catch (error) {
  await page.shot(`${out}/failed.png`).catch(() => {});
  console.log(await text(".sidebar").catch(() => ""));
  throw error;
} finally {
  await chrome.close();
}
