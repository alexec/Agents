// The #840 walk: accounts added to a runtime on the web page. Pairs, opens Runtimes, finds the
// added account's row under its runtime, adds one with Add Account…, removes it, and opens a new
// session to find the Account choice beside the runtime. Fails on any error the page throws.
//
//   node Web/test/walk/accounts840.mjs <WEB_URL> <browser code> <out dir>
//
// Expects the host to have one Claude account called Work, and a folder, as the run-app walk
// leaves them (`rpc.py $ROOT call runtimes/addAccount '{"runtimeID":"claude","name":"Work"}'`).

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/run-acct840-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);

  await page.eval(`location.hash = "#/a/runtimes"`);
  const rows = () => page.eval(`[...document.querySelectorAll(".runtime-list li .strong")].map((s) => s.textContent)`);
  await page.waitFor(`[...document.querySelectorAll(".runtime-list li .strong")].some((s) => s.textContent === "Claude · Work")`, 15_000);
  const listed = await rows();
  check(listed.indexOf("Claude · Work") === listed.indexOf("Claude") + 1, `the account's row is under Claude's: ${JSON.stringify(listed)}`);
  await page.shot(`${out}/web-1-runtimes.png`);

  // Add Account… on Claude's row, a name, then Add.
  await page.eval(`[...document.querySelectorAll(".runtime-list li")].find((li) => li.querySelector(".strong")?.textContent === "Claude")
    .querySelector("button:last-of-type").click()`);
  await page.waitFor(`document.querySelector(".add-account input")`, 5_000);
  await page.focus(".add-account input");
  await page.type("Personal");
  await sleep(200);
  await page.shot(`${out}/web-2-add-account.png`);
  await page.eval(`document.querySelector(".add-account button[type=submit]").click()`);
  await page.waitFor(`[...document.querySelectorAll(".runtime-list li .strong")].some((s) => s.textContent === "Claude · Personal")`, 15_000);
  check(true, `added: ${JSON.stringify(await rows())}`);

  // Remove it again, saying yes to the question.
  await page.eval(`window.confirm = (m) => { window.asked = m; return true; }`);
  await page.eval(`[...document.querySelectorAll(".runtime-list li")].find((li) => li.querySelector(".strong")?.textContent === "Claude · Personal")
    .querySelector("button:last-of-type").click()`);
  await page.waitFor(`![...document.querySelectorAll(".runtime-list li .strong")].some((s) => s.textContent === "Claude · Personal")`, 60_000);
  check(true, `removed: ${JSON.stringify(await rows())}`);
  const asked = await page.eval(`window.asked`);
  check(/^Remove Personal\? Nothing is running on it\. .* This can’t be undone\.$/.test(asked), `asked first: ${asked}`);

  // A new session on Claude offers the account.
  await page.eval(`[...document.querySelectorAll(".sidebar a, .sidebar button")].find((e) => e.textContent.trim().endsWith("New Session")).click()`);
  await page.waitFor(`document.querySelector("select[aria-label=Runtime]")`, 15_000);
  await page.eval(`(() => { const s = document.querySelector("select[aria-label=Runtime]"); s.value = "claude"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelector("select[aria-label=Account]")`, 10_000);
  const choices = await page.eval(`[...document.querySelector("select[aria-label=Account]").options].map((o) => o.textContent)`);
  check(JSON.stringify(choices) === JSON.stringify(["Your Own Sign-In", "Work · Not signed in"]), `the Account choices: ${JSON.stringify(choices)}`);
  await page.shot(`${out}/web-3-new-session.png`);
  const errors = page.errors ?? [];
  check(errors.length === 0, `no errors on the page: ${JSON.stringify(errors)}`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.stack ?? e}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
