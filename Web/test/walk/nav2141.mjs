// The #2141 walk: the page by section on a scratch control plane, its sessions synthetic (never a
// real record). The Overview, Agents with a chat open and its State filter, a section's list of
// pages, Settings with the admin's pages, an old #/console address at its new place, and the bar at
// a phone's width.
//
//   node Web/test/walk/nav2141.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

const chrome = await launch({ profile: `/tmp/run-nav2141-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-bar")`, 20_000);

  // The Overview, which the page opens on.
  await page.waitFor(`document.querySelector(".overview-grid")?.textContent.includes("Fix the login redirect")`, 30_000);
  const bar = (await page.text(".nav-bar")).replace(/\s+/g, " ");
  console.log(bar);
  check(/Overview/.test(bar) && /Agents/.test(bar) && /Machines/.test(bar) && /Settings/.test(bar), "the bar has the sections");
  check(/People/.test(bar) && /Requests/.test(bar), "an admin's bar has People and Requests");
  const overview = (await page.text(".overview-grid")).replace(/\s+/g, " ");
  check(/2 sessions/.test(overview), "Waiting for you counts the two sessions");
  check(/1 machine · 1 online/.test(overview), "Machines says how many are online");
  await pause(1500);
  await page.shot(`${out}/web-overview.png`);

  // Agents: a session that waits, from the Overview's card.
  await page.press("Fix the login redirect");
  await page.waitFor(`location.hash.includes("/s/") && document.querySelector(".sidebar .agent-filters")`, 20_000);
  await pause(1500);
  await page.shot(`${out}/web-agents.png`);
  check(await page.eval(`document.querySelector(".nav-item.on")?.textContent.startsWith("Agents")`), "a chat is in Agents");

  // The State filter: only the sessions that need you.
  await page.eval(`(() => { const s = document.querySelector('select[aria-label="State"]'); s.value = "needsYou"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await pause(800);
  const list = (await page.text(".sidebar")).replace(/\s+/g, " ");
  check(!/Flaky retry test/.test(list), "Needs You hides the finished sessions");
  await page.shot(`${out}/web-agents-needs-you.png`);
  await page.eval(`(() => { const s = document.querySelector('select[aria-label="State"]'); s.value = "any"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);

  // Machines: its list of pages, the fleet first.
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelector(".sub-app-list") && document.querySelector(".console-table")`, 20_000);
  await pause(1000);
  await page.shot(`${out}/web-machines.png`);

  // Reports: Events is under Records.
  await page.eval(`location.hash = "#/reports/events"`);
  await page.waitFor(`document.querySelector(".events-page")`, 20_000);
  await pause(1000);
  await page.shot(`${out}/web-reports-events.png`);

  // Settings, with the organisation's pages for an admin; an old Console address lands here.
  await page.eval(`location.hash = "#/console/policy"`);
  await page.waitFor(`location.hash === "#/settings/policy" && document.querySelector(".sub-app-row.on")?.textContent.startsWith("Policy")`, 20_000);
  check(true, "#/console/policy is written again as #/settings/policy");
  await pause(1000);
  await page.shot(`${out}/web-settings-policy.png`);

  // A phone's width: the bar is one menu.
  await page.eval(`location.hash = "#/agents"`);
  await page.viewport(390, 844);
  await pause(800);
  await page.shot(`${out}/web-narrow.png`);
  await page.eval(`document.querySelector(".nav-menu-button").click()`);
  await pause(400);
  await page.shot(`${out}/web-narrow-menu.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
