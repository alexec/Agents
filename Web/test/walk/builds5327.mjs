// The #5327 walk of Reports ▸ Planning ▸ Builds on a scratch control plane and host whose timing store holds a
// repository's runs (see builds5178.mjs): the host sends its copy to the control plane (builds/sync, #5232); then the
// host is stopped, as a Mac asleep, and the page still draws the trend, a change and a run from the control plane's
// copy (builds/historyAll, builds/runAll). Shots go to <out dir>/web-<state>.png.
//
//   node Web/test/walk/builds5327.mjs <WEB_URL> <browser code> <out dir> <repo, github:owner/name> <host pid> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, repo, hostPid, width = "1440"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const said = async (page) => (await page.text(".builds-page")).replace(/\s+/g, " ");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = await launch({ profile: `/tmp/b5327-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 1300 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  // Past the first-build question page (#5048), which a scratch set-up with no folder opens on; the machine lock's
  // cards are in the Agents sidebar.
  await page.eval(`localStorage.setItem("agents.firstBuild.page", "gone"); location.reload()`);
  await sleep(3000);
  await page.eval(`[...document.querySelectorAll("a, button")].find((x) => x.textContent.trim() === "Agents")?.click()`);
  await sleep(1500);
  // A fresh scratch set-up (#3492): this browser founds the machine lock and approves the scratch host into it.
  const pressed = (words) => page.eval(`(() => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent.trim() === ${JSON.stringify(words)} && !x.disabled);
    if (b) b.click(); return !!b; })()`);
  let approved = false;
  for (let i = 0; i < 60 && !approved; i++) {
    await pressed("Skip");
    if (await pressed("Compare Digits")) await sleep(1000);
    approved = await pressed("Approve");
    await sleep(500);
  }
  check(approved, "the scratch host approved into the machine lock");
  const open = async (query) => {
    await page.eval(`location.hash = ${JSON.stringify(`#/reports/value/builds?${query}`)}`);
    await sleep(800);
  };
  const trendDrawn = `document.querySelector(".builds-page .builds-chart rect.builds-run") && document.querySelectorAll(".builds-tiles li").length === 4`;

  // The host joins and sends its copy (a few seconds after it joins); the page reads the control plane's.
  await open(`repo=${repo}&range=month`);
  await page.waitFor(trendDrawn, 60_000);
  await sleep(1500);
  check((await said(page)).includes("Last update"), "the trend, with Last update, while the host answers");
  await page.shot(`${out}/web-trend-awake.png`);

  // The host stops: the Mac sleeps.
  process.kill(Number(hostPid), "SIGTERM");
  await sleep(4000);
  await page.eval(`location.reload()`);
  await sleep(4000);
  await open(`repo=${repo}&range=month&workflow=ci.yml`);
  await page.waitFor(trendDrawn, 30_000);
  await sleep(1500);
  let text = await said(page);
  check(!text.includes("None of your machines"), "no 'None of your machines' with the host stopped");
  check(text.includes("Last update"), "Last update with the host stopped");
  check(/time to green · median/i.test(text), "the tiles with the host stopped");
  await page.shot(`${out}/web-trend-asleep.png`);

  // A change, and its runs, from builds/runAll.
  const changes = await page.eval(`document.querySelectorAll(".builds-changes a").length`);
  check(changes > 0, `the changes listed (${changes})`);
  await page.eval(`document.querySelector(".builds-changes a").click()`);
  await sleep(3000);
  await page.shot(`${out}/web-change-asleep.png`);
  const compare = await page.eval(`(() => { const a = [...document.querySelectorAll("a")].find((x) => x.textContent === "Compare the two runs"); if (a) a.click(); return !!a; })()`);
  check(compare, "Compare the two runs on the change");
  await page.waitFor(`document.querySelector(".builds-gantt") && document.querySelector(".builds-steps")`, 20_000);
  await sleep(1000);
  text = await said(page);
  check(!/can’t be reached|no longer keeps/.test(text), "the run's jobs and steps from the control plane's copy");
  await page.shot(`${out}/web-run-asleep.png`);
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
