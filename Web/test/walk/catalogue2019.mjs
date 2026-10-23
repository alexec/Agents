// The #2019 M5 walk: on a scratch control plane whose machine has two MCP servers and a skill
// from a catalogue (catalog-mcp.json and catalog-skills.json in its root, never a real one), ask
// for an MCP server in Settings ▸ Policy, approve it in Console ▸ Requests, and see Console ▸
// Catalogue: who uses what, and the approval, then Take Back.
//
//   node Web/test/walk/catalogue2019.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const body = (page) => page.text("body").then((t) => t.replace(/\s+/g, " "));

const chrome = await launch({ profile: `/tmp/run-m5gov-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);

  await page.eval(`location.hash = "#/settings"`);
  const form = `section[aria-labelledby="settings-policy"]`;
  await page.waitFor(`document.querySelector('${form} input[aria-label="Name"]')`, 20_000);
  await page.eval(`document.querySelector('${form} input[aria-label="Name"]').scrollIntoView()`);
  await page.focus(`${form} input[aria-label="Name"]`);
  await page.type("github");
  await page.focus(`${form} input[aria-label="Why"]`);
  await page.type("To review pull requests");
  await page.press("Ask");
  await page.waitFor(`document.querySelector('${form}')?.textContent.includes("waiting for an admin")`, 10_000);
  check(true, "the ask is listed as waiting");
  await page.shot(`${out}/web-ask.png`);

  await page.eval(`location.hash = "#/console/requests"`);
  await page.waitFor(`document.body.textContent.includes("asks for the MCP server github")`, 10_000);
  const requests = await body(page);
  check(/MCP Servers and Skills/.test(requests), "Requests has the section");
  check(/Requests\s*1/.test(requests), "the count beside Requests says 1");
  await page.shot(`${out}/web-requests.png`);
  await page.press("Approve");
  await page.waitFor(`!document.body.textContent.includes("asks for the MCP server github")`, 10_000);
  check(true, "Approve takes it off the list");

  await page.eval(`location.hash = "#/console/catalogue"`);
  await page.waitFor(`document.querySelector(".console-table")?.textContent.includes("github")`, 10_000);
  const catalogue = await body(page);
  console.log(catalogue.slice(catalogue.indexOf("Who Uses What"), catalogue.indexOf("Who Uses What") + 700));
  check(/0\.20\.1/.test(catalogue) && /pdf/.test(catalogue) && /5b8c1f0e9a7d/.test(catalogue), "each item with its version");
  check(/1 machine: Local owner|1 machine/.test(catalogue), "who uses it");
  check(/MCP server github, for/.test(catalogue), "the approval is listed");
  await page.shot(`${out}/web-catalogue.png`);
  await page.eval(`window.confirm = (m) => { window.asked = m; return true; }`);
  await page.press("Take Back…");
  check(/^Take back the MCP server github for/.test(await page.eval(`window.asked`)), "Take Back… asks first (#2438)");
  await page.waitFor(`document.body.textContent.includes("Nothing is approved yet")`, 10_000);
  check(true, "Take Back removes the approval");

  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`document.querySelector('${form}')?.textContent.includes("approved for you")`, 10_000);
  check(true, "the person sees it approved");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await body(page).catch(() => "")).slice(0, 2000));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
