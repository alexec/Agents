// The #3816 walk on a scratch root with the fixture Azure DevOps (.agents/skills/run-app/scripts/fake-azure-devops.py):
// connect Azure DevOps, open the Azure Repos folder's set-up (its Tasks slot reads Azure Boards and
// names the project for Work), add the team Payments' board to the folder's project, and choose it in
// Work ▸ Issues: only the work items under the team's area path. Screenshots go to <out dir>. The
// browser joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/boards3816-azureboards.mjs <WEB_URL> <browser code> <folder path> <fixture URL> <token> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folderPath, fixture, token, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
// A field's value, as a person types it: Preact reads it from the input event.
const fill = (selector, value) => `(() => { const i = document.querySelector(${JSON.stringify(selector)});
  i.value = ${JSON.stringify(value)}; i.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`;
// A select by its label's words, set as a person picks it.
const choose = (label, words) => `(() => {
  const select = [...document.querySelectorAll("label")].find((l) => l.textContent.trim().startsWith(${JSON.stringify(label)}))?.querySelector("select");
  const option = [...(select?.options ?? [])].find((o) => o.textContent === ${JSON.stringify(words)});
  if (!option) return false;
  select.value = option.value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
})()`;

const chrome = await launch({ profile: `/tmp/run-ab3816-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`[...document.querySelectorAll("a, button")].some((e) => e.textContent.trim() === "Agents")`, 20_000);
  const asked = `document.body.innerText.includes("Approve this device on another of your devices.")`;
  /** Joins the lock when the page asks, with the recovery key, and opens the page again. */
  const joinLock = async () => {
    if (!await page.waitFor(asked, 5_000).then(() => true, () => false)) return;
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!${asked}`, 30_000);
    await page.eval(`location.reload()`);
    await sleep(1000);
    await page.waitFor(`document.body.innerText.includes("Agents")`, 20_000);
  };
  const folderPage = "#/h/mac/p/" + encodeURIComponent(`file://${folderPath}/`) + "/m/1";
  const openFolder = async () => {
    await page.eval(`location.hash = ${JSON.stringify(folderPage)}`);
    await joinLock();
    await page.waitFor(has("Set up · "), 20_000);
    await page.waitFor(`!document.body.textContent.includes("Reading…")`, 20_000).catch(() => null);
  };
  await openFolder();

  // Connect Azure DevOps with the fixture's organization.
  await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
  await joinLock();
  await page.waitFor(has("Connect Azure DevOps…"), 15_000);
  await page.press("Connect Azure DevOps…");
  await page.waitFor(has("Personal access token"), 5_000);
  await page.eval(fill(".token-form input:not([type=password])", `${fixture}/acme`));
  await page.eval(fill(".token-form input[type=password]", token));
  await page.press("Connect");
  await page.waitFor(has("Azure DevOps · "), 10_000);

  // The set-up reads the three slots, and the Tasks slot names the project for Work.
  await openFolder();
  const setup = await page.text(".connector-setup");
  check(setup.includes("Azure Boards work items") && setup.includes("Apple Pay sheet"), "the Tasks slot reads Azure Boards");

  // The team's board in the project's boards.
  await page.waitFor(`document.querySelector(".project-boards")`, 20_000);
  await page.eval(fill(`.project-boards input[placeholder="Name"]`, "Payments"));
  await page.eval(fill(`.project-boards input[placeholder="https://github.com/orgs/acme/projects/7"]`,
    `${fixture}/acme/Web%20Shop/_backlogs/backlog/Payments/Stories`));
  await page.press("Add Board");
  await page.waitFor(`document.querySelector(".project-boards li")?.textContent.includes("Azure Boards")`, 10_000);
  const card = await page.text(".project-boards");
  check(card.includes("Payments") && card.includes("/acme/Web%20Shop/_boards/board/t/Payments"), "the board is kept as the team's board, on Azure Boards");
  say(`card: ${card.replace(/\s+/g, " ").slice(0, 300)}`);
  await page.eval(`document.querySelector(".project-boards").scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/web-boards.png`);

  // Work ▸ Issues: every work item of the project, then only the team's.
  await page.eval(`location.hash = "#/work/issue"`);
  await page.waitFor(has("Coupon field hides behind the keyboard"), 30_000);
  check(await page.eval(has("Apple Pay sheet closes")), "Work lists the project's work items, which the set-up named");
  await sleep(500);
  await page.shot(`${out}/web-work-all.png`);
  check(await page.eval(choose("Board", "Payments")), "the Board menu has Payments");
  await page.waitFor(`!${has("Coupon field hides behind the keyboard")}`, 20_000).catch(() => null);
  await sleep(1000);
  check(await page.eval(has("Apple Pay sheet closes")) && !await page.eval(has("Coupon field hides behind the keyboard")),
    "the board lists only the work items under the team's area path");
  await page.shot(`${out}/web-work-board.png`);
} catch (e) {
  failed += 1;
  await page.shot(`${out}/web-failed.png`).catch(() => null);
  say(`FAIL at ${await page.eval("location.hash").catch(() => "?")}: ${e.message}`);
  say((await page.text().catch(() => "")).replace(/\s+/g, " ").slice(0, 600));
} finally {
  await chrome.close();
}
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
