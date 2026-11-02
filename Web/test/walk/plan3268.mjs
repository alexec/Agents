// An epic's plan (#3268): on a run-app root whose folder is on the fixture GitHub (forge3268-github.py,
// AGENTS_TEST_GITHUB_URL), open epic #40's page and see its Plan: the steps, a mark per child, the
// lead or Start lead; press Start lead and see the new-session form filled in for a lead.
// Screenshots into <out dir>, each named with <prefix>.
//
//   node Web/test/walk/plan3268.mjs <WEB_URL> <browser code> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-plan3268-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#40")`);
  await page.waitFor(`document.querySelectorAll(".work-plan-row").length === 5`, 30_000);
  await sleep(2500);
  const steps = await text(".work-plan-step h4");
  ok(`the steps: ${steps.join(" | ")}`, steps.length === 3 && steps[2] === "Step 3 · waits for #43");
  const marks = await text(".work-plan-mark");
  ok(`the marks: ${marks.join(" ")}`, marks[0] === "✓" && marks[1] === "✓" && marks[2] === "⊘");
  ok("a child blocked outside says by what", (await text(".work-plan-row")).some((r) => r.includes("blocked by #17")));
  await page.shot(`${out}/${prefix}.png`);
  const head = (await text(".work-plan-head button"))[0];
  ok(`the header's button: ${head}`, head === "Start lead" || head === "Open lead");
  if (head === "Start lead") {
    await page.eval(`[...document.querySelectorAll(".work-plan-head button")].find((b) => b.textContent === "Start lead").click()`);
    await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes("lead\` skill"))`, 30_000);
    ok("Start lead opens the form filled in for a lead", true);
    await sleep(800);
    await page.shot(`${out}/${prefix}-start-lead.png`);
  }
} finally {
  await chrome.close();
}
