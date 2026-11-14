// The #5179 walk of Reports ▸ Planning ▸ Builds ▸ one run (spec 5166, board 3) on a scratch control plane and host
// whose timing store holds a repository's runs (see builds5178.mjs): Compare the two runs from a change, the Gantt
// chart and the step diff, the queue panel, and the run that waited longest. Shots go to <out dir>/web-<state>.png.
//
//   node Web/test/walk/builds5179.mjs <WEB_URL> <browser code> <out dir> <repo, github:owner/name> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, repo, width = "1440"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const said = async (page) => (await page.text(".builds-page")).replace(/\s+/g, " ");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = await launch({ profile: `/tmp/b5179-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 1400 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  // A fresh scratch set-up (#3492): this browser founds the machine lock and approves the scratch host into it.
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

    // Board 2: the go-darwin change of 8 November, with Compare the two runs.
    await open(`repo=${repo}&range=month&workflow=ci.yml`);
    await page.waitFor(`[...document.querySelectorAll(".builds-changes a")].length > 0`, 20_000);
    await page.eval(`[...document.querySelectorAll(".builds-changes a")].find((a) => /go-darwin slower, (8|9) Nov/.test(a.textContent))?.click()`);
    await page.waitFor(`!document.querySelector(".builds-run-card")?.textContent.includes("Loading")`, 20_000);
    check(await page.eval(`[...document.querySelectorAll("a")].some((a) => a.textContent === "Compare the two runs")`), "Compare the two runs on the change");
    await page.shot(`${out}/web-change-compare.png`);

    // Board 3: the first slow run against the last fast one.
    await page.eval(`[...document.querySelectorAll("a")].find((a) => a.textContent === "Compare the two runs").click()`);
    await page.waitFor(`document.querySelector(".builds-gantt") && document.querySelector(".builds-steps")`, 20_000);
    await sleep(800);
    const text = await said(page);
    check(/time to green [\d.]+ min \(run [\d.]+ min, queue/.test(text) && text.includes("against"), `the run's line: ${text.slice(0, 200)}`);
    check(text.includes("Steps that changed most, against the run before: go-darwin first"), "the steps, go-darwin first");
    check(await page.eval(`document.querySelector(".builds-steps tbody tr td")?.textContent === "go-darwin"`), "go-darwin's step at the top");
    check(await page.eval(`document.querySelectorAll(".builds-gantt-before").length > 3`), "the run before as outlines");
    check(await page.eval(`document.querySelector(".builds-gantt-row.picked") !== null`), "go-darwin's row picked");
    check(text.includes("Open on GitHub"), "Open on GitHub");
    check(text.includes("go-darwin slower"), "the breadcrumb back to the change");
    check(await page.eval(`location.hash.includes("drill=") && location.hash.includes("against=")`), "the run in the address");
    check(await page.eval(`document.querySelector(".builds-queue-panel") !== null`), "the queue panel beside a run whose own wait is short");
    await page.waitFor(`document.querySelector(".builds-queue-jobs") !== null`, 20_000).catch(() => {});
    await page.shot(`${out}/web-run.png`);

    // The run of the range that waited longest for a runner, from the panel.
    await page.eval(`[...document.querySelectorAll(".builds-queue-panel a")].find((a) => a.textContent.startsWith("Open that run")).click()`);
    await page.waitFor(`document.querySelector(".builds-gantt") && !document.querySelector(".builds-queue-panel")`, 20_000);
    await sleep(800);
    check(await page.eval(`document.querySelector(".builds-gantt-row.picked") !== null`), "the waiting job picked");
    await page.shot(`${out}/web-run-longest-wait.png`);

    // A run the store does not keep.
    await open(`repo=${repo}&range=month&workflow=ci.yml&drill=github:run:alexec/agents%231`);
    await page.waitFor(`document.querySelector(".builds-drill .hint")?.textContent.includes("no longer keeps")`, 20_000);
    await page.shot(`${out}/web-run-gone.png`);
  } catch (error) {
    await page.shot(`${out}/debug.png`).catch(() => {});
    console.log((await page.text("main, body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
    throw error;
  }
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
