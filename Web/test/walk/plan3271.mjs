// Changing an epic's plan (#3271): on a run-app root whose folder is on the fixture GitHub
// (forge3271-github.py, AGENTS_TEST_GITHUB_URL), open epic #40's page; set #45 blocked by #43 from
// its row's Blocked by menu and see it move to step 3; add a new child by its title and an issue
// that is there by #17, and see each in the plan. Screenshots into <out dir>, each named with <prefix>.
//
//   node Web/test/walk/plan3271.mjs <WEB_URL> <browser code> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-plan3271-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 1000 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);
const stepOf = (n) => page.eval(`(() => {
  for (const s of document.querySelectorAll(".work-plan-step"))
    if ([...s.querySelectorAll(".work-ref")].some((r) => r.textContent.trim() === "#${n}")) return s.querySelector("h4").textContent.trim();
  return null; })()`);
const addChild = async (words) => {
  await page.focus(".work-plan-add input");
  await page.eval(`document.querySelector(".work-plan-add input").select()`);
  await page.type(words);
  await page.press("Add child");
};

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#40")`);
  await page.waitFor(`document.querySelectorAll(".work-plan-row").length === 5`, 30_000);
  await sleep(2500);
  ok("each row has Blocked by", (await text(".work-plan-blocked")).length === 5);
  ok("Add child is under the steps", (await text(".work-plan-add button")).includes("Add child"));
  ok(`#45 starts in ${await stepOf(45)}`, (await stepOf(45))?.startsWith("Step 1"));
  await page.shot(`${out}/${prefix}-plan.png`);

  await page.eval(`[...document.querySelectorAll(".work-plan-item")].find((li) => li.querySelector(".work-ref").textContent.trim() === "#45")
    .querySelector(".work-plan-blocked").click()`);
  await page.waitFor(`document.querySelector(".context-menu")`);
  const items = await text(".context-menu [role=menuitem]");
  ok(`the menu offers the others: ${items.join(" | ")}`, items.length === 4 && items.every((i) => !i.includes("#45")));
  await page.shot(`${out}/${prefix}-blocked-by-menu.png`);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent.includes("#43")).click()`);
  await page.waitFor(`[...document.querySelectorAll("[role=status]")].some((s) => s.textContent.includes("Blocked by changed."))`, 30_000);
  for (let i = 0; i < 60 && !(await stepOf(45))?.startsWith("Step 3"); i++) await sleep(500);
  ok(`#45 is now in ${await stepOf(45)}`, (await stepOf(45))?.startsWith("Step 3"));
  await sleep(1000);
  await page.shot(`${out}/${prefix}-blocked.png`);

  await addChild("Gift card refunds");
  await page.waitFor(`(document.querySelector(".work-plan-add input")?.value ?? "x") === "" && [...document.querySelectorAll(".work-plan-title")].some((t) => t.textContent === "Gift card refunds")`, 30_000);
  ok("a new child is in the plan", true);
  ok("the new child has its level", (await text(".work-plan-item")).some((r) => r.includes("task") && r.includes("Gift card refunds")));
  await addChild("#17");
  await page.waitFor(`[...document.querySelectorAll(".work-plan-title")].some((t) => t.textContent === "Document the coupon field")`, 30_000);
  ok("an issue that is there joins the plan", true);
  await sleep(1000);
  await page.shot(`${out}/${prefix}-added.png`);
} finally {
  await chrome.close();
}
