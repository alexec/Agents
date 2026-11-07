// No Labels on a Bitbucket pull request's page (#3881): on a run-app root whose folder's remote is
// git@bitbucket.org:agentstest/agents-walk.git, with the host's Bitbucket connection made at the
// fake Bitbucket (`Web/test/walk/forge3881-bitbucket.py`, BITBUCKET_API_URL), open issue #1 (its
// actions keep Labels) and pull request #3 (its actions have none). Screenshots into <out dir>. The
// browser joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/work3881.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-bb3881-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const actions = () => page.eval(`[...document.querySelectorAll(".work-actions button")].map((b) => b.textContent.trim())`);
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

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("bitbucket:agentstest/agents-walk#1")`);
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Start Agent")`, 30_000);
  await sleep(1000);
  ok(`an issue's page keeps Labels: ${(await actions()).join(", ")}`, (await actions()).includes("Labels ▾"));
  await page.shot(`${out}/web-issue-labels.png`);

  await page.eval(`location.hash = "#/work/pr/" + encodeURIComponent("bitbucket:agentstest/agents-walk#3")`);
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Show Diff")`, 30_000);
  await sleep(1000);
  ok(`a pull request's page has no Labels: ${(await actions()).join(", ")}`, !(await actions()).includes("Labels ▾"));
  await page.shot(`${out}/web-pr-no-labels.png`);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 400)}`);
  throw e;
} finally {
  await chrome.close();
}
