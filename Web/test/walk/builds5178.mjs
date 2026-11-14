// The #5178 walk of Reports ▸ Planning ▸ Builds on a scratch control plane and host whose timing store holds a
// repository's runs (<root>/ci-timings/github/<owner>/<repo>/<day>.jsonl and state.json): the trend, P90, a change
// picked, and the empty states. Shots go to <out dir>/web-<state>.png.
//
//   node Web/test/walk/builds5178.mjs <WEB_URL> <browser code> <out dir> <repo, github:owner/name> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, repo, width = "1440"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".builds-page")`;
const said = async (page) => (await page.text(".builds-page")).replace(/\s+/g, " ");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = await launch({ profile: `/tmp/run-b5178-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 1300 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  // A fresh scratch set-up (#3492): this browser founds the machine lock, skips the recovery key, and approves the
  // scratch host into it (Compare Digits, then Approve), so the host takes its requests.
  const pressed = (words) => page.eval(`(() => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent.trim() === ${JSON.stringify(words)} && !x.disabled);
    if (b) b.click(); return !!b; })()`);
  for (let i = 0, approved = false; i < 40 && !approved; i++) {
    await pressed("Skip");
    if (await pressed("Compare Digits")) await sleep(1000);
    approved = await pressed("Approve");
    await sleep(500);
  }
  await sleep(2000);
  try {

  const open = async (query) => {
    await page.eval(`location.hash = ${JSON.stringify(`#/reports/value/builds?${query}`)}`);
    await sleep(800);
  };

  // Board 1: the trend, 30 days, ci, main.
  await open(`repo=${repo}&range=month`);
  await page.waitFor(`${pane}?.querySelector(".builds-chart rect.builds-run") && document.querySelectorAll(".builds-tiles li").length === 4`, 20_000);
  let text = await said(page);
  check(/time to green · median/i.test(text) && /queue time · median/i.test(text), "the four tiles");
  check(text.includes("Changes in this range") && /slower, \d+ \w+/.test(text), "the changes listed");
  check(text.includes("Last update"), "Last update under the title");
  check(await page.eval(`[...document.querySelectorAll(".sub-app-row.under")].some((b) => b.textContent.trim() === "Builds" && b.classList.contains("on"))`),
    "Builds under Planning, chosen");
  check(await page.eval(`location.hash.includes("workflow=ci.yml")`), "the workflow ci to start with, in the address");
  await page.shot(`${out}/web-trend.png`);

  // Median | P90.
  await page.press("P90");
  await sleep(500);
  check(await page.eval(`location.hash.includes("stat=p90")`), "P90 in the address");
  await page.shot(`${out}/web-trend-p90.png`);

  // One job.
  await open(`repo=${repo}&range=month&workflow=ci.yml&job=go-darwin`);
  await page.waitFor(`${pane}?.textContent.includes("go-darwin: Time to green")`, 20_000);
  await page.shot(`${out}/web-trend-job.png`);

  // Board 2: the go-darwin change of 8 November picked from the list.
  await open(`repo=${repo}&range=month&workflow=ci.yml`);
  await page.waitFor(`[...document.querySelectorAll(".builds-changes a")].length > 0`, 20_000);
  await page.eval(`[...document.querySelectorAll(".builds-changes a")].find((a) => /go-darwin slower, 9 Nov|go-darwin slower, 8 Nov/.test(a.textContent))?.click()`);
  await page.waitFor(`document.querySelector(".builds-change h2")`, 20_000);
  await page.waitFor(`!document.querySelector(".builds-run-card")?.textContent.includes("Loading")`, 20_000);
  text = await said(page);
  check(/go-darwin slower from \d+ November/.test(text), `the heading: ${text.slice(0, 120)}`);
  check(text.includes("First slow run"), "the first slow run");
  check(text.includes("Did not run go-darwin") || text.includes("cancelled"), "a commit that did not run the job");
  check(text.includes("The whole run: time to green"), "the run cards");
  await page.shot(`${out}/web-change.png`);

  // Board 4: no runs in the range (the last 24 hours).
  await open(`repo=${repo}&range=day&workflow=ci.yml`);
  await page.waitFor(`${pane}?.textContent.includes("Try a longer range")`, 20_000);
  await page.shot(`${out}/web-empty-range.png`);

  // A forge with no reader.
  await open(`repo=forgejo:codeberg.org/scratch/app&range=week`);
  await page.waitFor(`${pane}?.textContent.includes("Agents does not read its CI runs yet")`, 20_000);
  await page.shot(`${out}/web-empty-forge.png`);

  // A repository the machine has not read.
  await open(`repo=github:scratch/walk&range=week`);
  await page.waitFor(`${pane}?.textContent.includes("has not read the CI runs")`, 20_000);
  await page.shot(`${out}/web-empty-unread.png`);

  } catch (error) {
    await page.shot(`${out}/debug.png`).catch(() => {});
    console.log((await page.text("main, body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
    throw error;
  }
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
