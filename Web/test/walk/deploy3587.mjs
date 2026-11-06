// A waiting deploy (#3587): on a run-app root whose folder is on the fixture GitHub
// (deploy3587-github.py, AGENTS_TEST_GITHUB_URL), see the Deploy row in Needs You, open its Review
// page with what ships, and Approve it: the row leaves. Screenshots into <out dir>. The browser
// joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/deploy3587.mjs <WEB_URL> <browser code> <out dir>

import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-d3587-chrome-${process.pid}` });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;

let page;
/** Shoots the page, then cuts it to the element `selector` finds, with a margin. */
const shoot = async (name, selector) => {
  await page.eval(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({ block: "center" })`);
  await sleep(500);
  const r = await page.eval(`(() => { const b = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
    const s = devicePixelRatio; return [b.x, b.y, b.width, b.height].map((n) => Math.round(n * s)); })()`);
  const path = `${out}/${name}.png`;
  await page.shot(path);
  const [x, y, w, h] = r, m = 12;
  execFileSync("sips", ["-c", String(h + 2 * m), String(w + 2 * m), "--cropOffset", String(Math.max(0, y - m)), String(Math.max(0, x - m)), path, "--out", path]);
};

try {
  page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(has("Overview"), 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(2000);
  // The browser joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
  if (await page.eval(has("Approve this device on another of your devices."))) {
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!${has("Approve this device on another of your devices.")}`, 30_000);
    await page.eval(`location.reload()`);
    await sleep(1000);
    await page.eval(`location.hash = "#/agents"`);
  }
  await page.waitFor(has("Release to production"), 200_000).catch(async (e) => { await page.shot(`${out}/dbg.png`); throw e; });
  ok("Needs You lists the deploy", await page.eval(has("Deploy · v1.3.0 waits for your approval")));
  await page.eval(`document.querySelector("button.approval").closest("details").id = "needs-you-3587"`);
  await shoot("web-needs-you", "#needs-you-3587");

  await page.eval(`document.querySelector("button.approval").click()`);
  await page.waitFor(has("Ships since v1.2.0"), 30_000);
  ok("the Review page says what ships", await page.eval(has("Coupon codes ignore case (#24)")));
  await shoot("web-review", ".review-page");

  await page.eval(`[...document.querySelectorAll(".review-bar button")].find((b) => b.textContent.trim() === "Approve").click()`);
  await page.waitFor(`!${has("Release to production")}`, 30_000);
  ok("Approve takes it out of Needs You", true);
} finally {
  await chrome.close();
}
