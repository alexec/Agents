// Linear's whole workspace in Work ▸ Issues (#3311): on a run-app root pointed at the fixture
// Linear (forge3311-linear.py) whose folders name no linearTeams, open Work ▸ Issues and see the
// issues of both teams, each team a choice of the Repo filter (Linear · ENG, Linear · OPS); choose
// OPS and see only its issue; open ENG-41's page with Start Agent. Screenshots into <out dir>.
//
//   node Web/test/walk/work3311.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-linear3311-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const rows = () => page.eval(`document.querySelectorAll(".work-row").length`);
const repos = () => page.eval(`[...document.querySelectorAll(".work-filters select")].find((s) => s.closest("label")?.textContent.includes("Repo"))
  ? [...[...document.querySelectorAll(".work-filters select")].find((s) => s.closest("label").textContent.includes("Repo")).options].map((o) => o.textContent)
  : []`);

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 3`, 30_000);
  ok("the open issues of both teams are listed", (await rows()) === 3);
  ok(`each team is a Repo choice: ${await repos()}`, (await repos()).join(",") === "All,Linear · ENG,Linear · OPS");
  await sleep(400);
  await page.shot(`${out}/web-issues.png`);

  await page.eval(`(() => { const s = [...document.querySelectorAll(".work-filters select")].find((s) => s.closest("label").textContent.includes("Repo"));
    s.value = [...s.options].find((o) => o.textContent === "Linear · OPS").value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelectorAll(".work-row").length === 1`, 10_000);
  ok("Linear · OPS has only its issue", await page.eval(`document.querySelector(".work-row").textContent.includes("OPS-7")`));
  await sleep(300);
  await page.shot(`${out}/web-issues-team.png`);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("linear:ENG-41")`);
  await page.waitFor(`document.querySelector(".work-actions") && document.querySelector(".work-comment-box")`, 30_000);
  ok("the page has Start Agent, Close and Open on Linear",
    await page.eval(`(() => { const t = [...document.querySelectorAll(".work-actions button")].map((b) => b.textContent);
      return t.includes("Start Agent") && t.includes("Close") && [...document.querySelectorAll("a")].some((a) => a.textContent === "Open on Linear"); })()`));
  await sleep(400);
  await page.shot(`${out}/web-issue.png`);
} finally {
  await chrome.close();
}
