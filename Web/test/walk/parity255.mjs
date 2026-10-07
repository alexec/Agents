// The page's prompt lists, cards and new-session bar (#255, #256, #257), walked against a scratch
// root with one git project: its new-session bar (places, runtimes, sandbox, `/` commands), a
// Claude session started from it in plan mode (its plan approval, answered by ⌥n), and `@` files
// in that session's prompt. Reads back what each shows; shots beside the notes.
//
//   node Web/test/walk/parity255.mjs <WEB_URL> <browser code> <project name> <out dir>
//
// The code is a browser's (`agents-control code --client --browser`).

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, project, out] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };

const chrome = await launch({ profile: `/tmp/255-walk-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.project")`, 20_000);
  // The project's row opens its new session, at /n/1, as New Session in its menu does.
  await page.eval(`(() => {
    const row = [...document.querySelectorAll(".sidebar .row.project")].find((r) => r.querySelector(".title")?.textContent.includes(${JSON.stringify(project)}));
    row?.querySelector("button.pick")?.click();
  })()`);
  await page.waitFor(`location.hash.includes("/n/1")`, 10_000);
  await page.waitFor(`document.querySelector(".new-agent .menus") || document.querySelector(".new-agent .failure")`, 90_000);

  // #257: what each menu offers.
  const select = (label) => page.eval(`[...document.querySelector('select[aria-label=${JSON.stringify(label)}]')?.querySelectorAll("option") ?? []]
    .map((o) => (o.parentElement.tagName === "OPTGROUP" ? o.parentElement.label + " / " : "") + o.textContent + (o.disabled ? " [greyed]" : ""))`);
  say(`works in: ${JSON.stringify(await select("Works in"))}`);
  say(`runtime: ${JSON.stringify(await select("Runtime"))}`);
  say(`sandbox: ${JSON.stringify(await select("Command sandbox"))}`);
  say(`sandbox pill: ${JSON.stringify(await page.text(".new-agent .menus label[title='Command sandbox'] span"))}`);
  await page.shot(`${out}/257-new-session.png`);

  // #255: `/` lists the draft runtime's commands; ↓ and Tab take the second.
  await page.focus(".new-agent textarea");
  await page.type("/");
  await page.waitFor(`document.querySelector(".completions")`, 10_000);
  say(`commands for "/": ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".completions li code:first-child")].slice(0, 6).map((c) => c.textContent)`))}`);
  await page.type("re");
  await sleep(100);
  say(`commands for "/re": ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".completions li code:first-child")].map((c) => c.textContent)`))}`);
  await page.shot(`${out}/255-commands.png`);
  await page.key("ArrowDown");
  await page.key("Tab");
  await sleep(100);
  say(`after ↓ Tab: ${JSON.stringify(await page.eval(`document.querySelector(".new-agent textarea").value`))}; list up: ${await page.eval(`!!document.querySelector(".completions")`)}`);
  await page.eval(`(() => { const t = document.querySelector(".new-agent textarea"); t.value = ""; t.dispatchEvent(new Event("input", { bubbles: true })); })()`);

  // #256: a Claude session in plan mode, asked for a plan.
  const planMode = await page.eval(`(() => {
    const s = [...document.querySelectorAll(".new-agent select")].find((x) => [...x.options].some((o) => /plan/i.test(o.textContent)));
    if (!s) return null;
    const i = [...s.options].findIndex((o) => /plan/i.test(o.textContent));
    s.value = s.options[i].value; s.dispatchEvent(new Event("change", { bubbles: true }));
    return s.options[i].textContent;
  })()`);
  say(`mode chosen: ${planMode}`);
  await page.focus(".new-agent textarea");
  await page.type("Plan adding a CONTRIBUTING.md that says how to run the tests. Keep the plan to three steps. Then ask me to approve it.");
  await page.key("Enter");
  await page.waitFor(`document.querySelector(".chat:not(.new-agent)")`, 60_000);
  await page.waitFor(`document.querySelector('.card[aria-label="Permission request"]')`, 240_000);
  await sleep(500);
  const card = await page.text('.card[aria-label="Permission request"]');
  say(`plan card: ${JSON.stringify(card)}`);
  say(`says switch_mode: ${card.includes("switch_mode")}; Show plan: ${await page.eval(`!!document.querySelector(".plan-shown button")`)}; plan text: ${await page.eval(`!!document.querySelector(".plan-text")`)}`);
  say(`answers and keys: ${JSON.stringify(await page.eval(`[...document.querySelectorAll('.card[aria-label="Permission request"] .options button')].map((b) => b.textContent + " " + (b.title || "") + (b.hasAttribute("data-default") ? " (Return)" : ""))`))}`);
  await page.shot(`${out}/256-plan-card.png`);
  if (await page.eval(`!!document.querySelector(".plan-shown button")`)) {
    await page.press("Show plan");
    await sleep(1500);
    await page.waitFor(`document.querySelector(".live-page .markdown")`, 10_000).catch(() => {});
    say(`after Show plan: files pane open ${await page.eval(`location.hash.includes("/f/1")`)}; page shows ${JSON.stringify((await page.text(".live-page")).slice(0, 160))}`);
    await page.shot(`${out}/256-show-plan.png`);
  }
  // The last answer by ⌥n, which is not an approval: the card goes.
  const count = await page.eval(`document.querySelectorAll('.card[aria-label="Permission request"] .options button[data-answer]').length`);
  await page.eval(`document.activeElement?.blur()`);
  await page.key("¡", { code: `Digit${count}`, modifiers: 1 });
  await page.waitFor(`!document.querySelector('.card[aria-label="Permission request"]')`, 20_000)
    .then(() => say(`⌥${count} answered the card`), () => say(`⌥${count} left the card up`));

  // #255: `@` in the open session's prompt finds files on the host.
  await page.focus(".chat .foot textarea");
  await page.type("look at @READ");
  await page.waitFor(`document.querySelector('.completions[aria-label="Files"]')`, 10_000);
  say(`files for "@READ": ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".completions li")].map((l) => l.innerText.replace(/\\n/g, " "))`))}`);
  await page.shot(`${out}/255-mentions.png`);
  await page.key("Enter");
  await sleep(200);
  say(`after Return: ${JSON.stringify(await page.eval(`document.querySelector(".chat .foot textarea").value`))}; attached ${JSON.stringify(await page.text(".chat .attachments"))}`);
  await page.shot(`${out}/255-mention-taken.png`);
  // #266: an edit's permission card shows the change, as the Remote's.
  await page.eval(`(() => { const t = document.querySelector(".chat .foot textarea"); t.value = ""; t.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.eval(`[...document.querySelectorAll(".chat .foot .attachments .remove")].forEach((b) => b.click())`);
  const asked = await page.eval(`(() => {
    const s = [...document.querySelectorAll(".chat .foot select")].find((x) => [...x.options].some((o) => /^default$|ask/i.test(o.textContent)));
    if (!s) return null;
    const o = [...s.options].find((o) => /^default$|ask/i.test(o.textContent));
    s.value = o.value; s.dispatchEvent(new Event("change", { bubbles: true }));
    return o.textContent;
  })()`);
  say(`mode for the edit: ${asked}`);
  await sleep(1500);
  await page.focus(".chat .foot textarea");
  await page.type("Change app.py so it prints hello instead of hi. Use your edit tool; do nothing else.");
  await page.key("Enter");
  await page.waitFor(`document.querySelector('.card[aria-label="Permission request"]')`, 240_000);
  await sleep(500);
  say(`edit card: ${JSON.stringify(await page.text('.card[aria-label="Permission request"]'))}`);
  say(`edit card diff: ${await page.eval(`!!document.querySelector('.card[aria-label="Permission request"] .call-diff')`)}`);
  await page.shot(`${out}/266-edit-card.png`);
  const edits = await page.eval(`document.querySelectorAll('.card[aria-label="Permission request"] .options button[data-answer]').length`);
  await page.eval(`document.activeElement?.blur()`);
  await page.key("¡", { code: `Digit${edits}`, modifiers: 1 });
  await page.waitFor(`!document.querySelector('.card[aria-label="Permission request"]')`, 20_000).catch(() => {});
  say(`checks: errors ${JSON.stringify(page.errors ?? [])}`);
} catch (error) {
  say(`failed: ${error.message}; the page said ${JSON.stringify((await page.text().catch(() => "")).slice(0, 400))}`);
  await page.shot(`${out}/failed.png`).catch(() => {});
  process.exitCode = 1;
} finally {
  writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
  await chrome.close();
}
