// A standing epic's plan (#3662): on a run-app root whose folder is on the fixture GitHub
// (forge3662-github.py, AGENTS_TEST_GITHUB_URL), open the standing epic #60's page and see its
// Plan: the query in words, its open bugs with no milestone in one list with no steps, the header
// with no end, and no Add child or Blocked by; then #61, whose block is bad, and see why it has no
// query. Screenshots into <out dir>, each named with <prefix>. The browser joins the scratch root's
// lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/plan3662.mjs <WEB_URL> <browser code> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-plan3662-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);

const asked = `document.body.innerText.includes("Approve this device")`;

/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
async function joinLock() {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
}

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await joinLock();

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#60")`);
  await page.waitFor(`document.querySelectorAll(".work-plan-row").length === 4`, 30_000);
  await sleep(2500);
  const refs = await text(".work-plan-row .work-ref");
  ok(`the query's issues in order: ${refs.join(" ")}`, refs.join(" ") === "#71 #72 #73 #74");
  ok("no step header", (await text(".work-plan-step h4")).length === 0);
  const head = (await text(".work-plan-head .quiet")).join(" | ");
  ok(`the header has no end: ${head}`, head.includes("Standing · 4 open"));
  ok("the query in words", (await text(".work-plan p")).some((t) => t === "Open issues labelled bug · no milestone · 1 lane at a time"));
  ok("no Add child or Blocked by", (await text(".work-plan-add, .work-plan-blocked")).length === 0);
  ok("Start lead", (await text(".work-plan-head button"))[0] === "Start lead");
  await page.shot(`${out}/${prefix}-standing.png`);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#61")`);
  await page.waitFor(`document.querySelector(".work-plan .failure")`, 30_000);
  await sleep(1500);
  ok("a bad block says why", (await text(".work-plan .failure"))[0]?.includes("unknown field"));
  ok("no count with an error", (await text(".work-plan-head .quiet")).includes("Standing"));
  await page.shot(`${out}/${prefix}-error.png`);
} catch (e) {
  await page.shot(`${out}/${prefix}-failed.png`);
  throw e;
} finally {
  await chrome.close();
}
