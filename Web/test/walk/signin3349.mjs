// The #3349 walk: a server's Claude signed in from the web page, with no browser on the server.
// Pairs, opens Runtimes, finds the server's Claude "Not signed in on this machine" with Sign In…,
// opens the sheet (the link `claude setup-token` gave on the server), types a code Claude does
// not take, switches to an API key, and signs in with it. Fails on any error the page throws.
//
//   node Web/test/walk/signin3349.mjs <WEB_URL> <browser code> <server name> <out dir>
//
// Expects a server with Claude's toolset and no sign-in, joined to the control plane: the
// bare box of the test-servers skill, joined with the shown command, with a Mac that lends none.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, server, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/run-s3349-chrome-${process.pid}` });

// The server's section, and Claude's row in it.
const section = `[...document.querySelectorAll(".runtimes-page section")].find((s) => s.querySelector("h2")?.textContent === ${JSON.stringify(server)})`;
const claudeRow = `[...(${section})?.querySelectorAll(".runtime-list li") ?? []].find((li) => li.querySelector(".strong")?.textContent === "Claude")`;
const rowText = () => page.eval(`${claudeRow}?.textContent ?? ""`);
let page;

try {
  page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar") && !document.querySelector("textarea[aria-label]")`, 20_000).catch(() => {});
  await sleep(2000);

  await page.eval(`location.hash = "#/a/runtimes"`);
  await page.waitFor(`(${claudeRow})?.textContent.includes("Sign In…")`, 30_000);
  check(true, `the server's Claude: ${await rowText()}`);
  await page.eval(`(${section}).scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-runtimes.png`);

  // Sign In… opens the sheet with the link from the server.
  await page.eval(`[...(${claudeRow}).querySelectorAll("button")].find((b) => b.textContent === "Sign In…").click()`);
  await page.waitFor(`document.querySelector(".runtime-sign-in .sign-in-link a")`, 60_000);
  const link = await page.eval(`document.querySelector(".runtime-sign-in .sign-in-link a").href`);
  check(/^https:\/\/claude\.(ai|com)\/.*oauth\/authorize\?/.test(link), `the link is Claude's: ${link.slice(0, 60)}…`);
  await page.shot(`${out}/web-sheet.png`);

  // A code Claude does not take says so in the sheet.
  await page.focus(`.runtime-sign-in input[aria-label=Code]`);
  await page.type("not-a-real-code#walk");
  await sleep(200);
  await page.shot(`${out}/web-code.png`);
  await page.eval(`document.querySelector(".runtime-sign-in button[type=submit]").click()`);
  await page.waitFor(`document.querySelector(".runtime-sign-in [role=alert]")`, 100_000);
  const said = await page.eval(`document.querySelector(".runtime-sign-in [role=alert]").textContent`);
  check(said.startsWith("Claude did not take that code"), `refused: ${said}`);
  await page.shot(`${out}/web-error.png`);

  // An API key instead.
  await page.press("Use an API Key Instead");
  await page.waitFor(`document.querySelector(".runtime-sign-in input[type=password]")`, 5_000);
  await page.focus(`.runtime-sign-in input[type=password]`);
  await page.type("sk-ant-api03-scratch-walk-key");
  await sleep(200);
  await page.shot(`${out}/web-key.png`);
  await page.eval(`document.querySelector(".runtime-sign-in button[type=submit]").click()`);
  await page.waitFor(`!document.querySelector(".runtime-sign-in")`, 30_000);
  await page.waitFor(`(${claudeRow})?.textContent.includes("Signed in on this machine")`, 10_000);
  check(!(await rowText()).includes("Sign In…"), `signed in: ${await rowText()}`);
  await page.eval(`(${section}).scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-signed-in.png`);

  const errors = await page.eval(`(window.__errors ?? []).length`).catch(() => 0);
  check(!errors, `no errors on the page`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.message}`);
  if (page) await page.shot(`${out}/web-failed.png`).catch(() => {});
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
