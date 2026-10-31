// The #1634 walk on a scratch root signed in to a real gitlab.com account: Connectors with
// the GitLab connection, a GitLab folder's Connectors page (#1632), and a session whose agent
// opened the gitlab server's views (#1631), each Show pressed. Screenshots go to <out dir>.
//
//   node Web/test/walk/gitlab1634.mjs <WEB_URL> <browser code> <folder name> <session title words> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderName, sessionWords, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${js(text)})`;

const chrome = await launch({ profile: `/tmp/run-gl34-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(has(folderName), 20_000);

  await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
  await page.waitFor(has("Disconnect"), 15_000);
  const connections = (await page.text(".connections")).replace(/\s+/g, " ");
  check(connections.includes("GitLab · agentstest") && connections.includes("Access token · ends"), `your connectors: ${connections}`);
  await page.shot(`${out}/web-1-your-connectors.png`);

  await page.eval(`location.hash = "#/h/mac/p/" + encodeURIComponent("file://" +
    document.querySelector('button[data-fold=folder]').title + "/") + "/m/1"`);
  await page.waitFor(has("Set up · "), 20_000);
  await page.waitFor(`!document.body.textContent.includes("Reading…")`, 20_000).catch(() => null);
  const setup = (await page.text(".connector-setup")).replace(/\s+/g, " ");
  check(setup.includes("gitlab.com/agentstest-group/agents-walk") && setup.includes("GitLab merge requests"), `connectors: ${setup.slice(0, 400)}`);
  await page.shot(`${out}/web-2-connectors.png`);

  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(folderName)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`[...document.querySelectorAll(".sidebar .row.session")].some((r) => r.textContent.includes(${js(sessionWords)}))`, 20_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.session")].find((r) => r.textContent.includes(${js(sessionWords)})).click()`);
  await page.waitFor(`document.querySelector(".app-view .view-ask, .view-layer iframe")`, 20_000);
  for (let i = 0; i < 3 && await page.eval(`!!document.querySelector(".app-view .view-ask")`); i++) {
    await page.press("Show");
    await sleep(1500);
  }
  await page.waitFor(`document.querySelectorAll(".view-layer iframe").length >= 3`, 20_000).catch(() => null);
  await sleep(4000);
  const frames = await page.eval(`document.querySelectorAll(".view-layer iframe").length`);
  check(frames >= 3, `views drawn: ${frames}`);
  await page.eval(`document.querySelector(".view-slot")?.scrollIntoView({ block: "start" })`);
  await sleep(800);
  await page.shot(`${out}/web-3-views.png`);
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
