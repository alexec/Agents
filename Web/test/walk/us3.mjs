// The US3 walk (071 quickstart §5, T059): send, start and steer from headless Chrome, with a real
// Claude agent on a scratch root, and the scratch window opened on the same session after each
// step to show it there too.
//
//   node Web/test/walk/us3.mjs <WEB_URL> <CONTROL_URL> <operator code> <picture> <out dir> <window script>
//
// `window script` is called as `<script> open <agent id>` to put the scratch window on the
// session, and `<script> shot <png>` to capture it. The operator client reads the host's record
// after each step, as the window would.

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";
import { Operator } from "./operator.mjs";

const [webURL, controlURL, operatorCode, picture, out, windowScript] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const window = (...args) => {
  try { execFileSync(windowScript, args, { stdio: "pipe", timeout: 60_000 }); return true; } catch (error) {
    say(`window ${args[0]} failed: ${String(error.stderr ?? error.message).trim().split("\n").pop()}`);
    return false;
  }
};

const op = await Operator.pair(controlURL, operatorCode);
const host = (await op.call("hosts/list")).find((h) => h.state === "online")?.id;
const record = async (id) => (await op.link.call("agents/list", { includeArchived: true, archivedOnly: false, archivedCommands: false }, host))
  .find((a) => a.id === id);
const until = async (what, test, seconds = 60) => {
  for (let i = 0; i < seconds * 4; i++) {
    const value = await test();
    if (value) return value;
    await sleep(250);
  }
  throw new Error(`waited ${seconds} s for ${what}`);
};

const chrome = await launch({ profile: `/tmp/071-us3-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type((await op.call("clients/startPairing", { grant: "device", kind: "browser" })).text);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);
const clickText = (selector, text) => page.eval(`(() => {
  const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)}) && e.offsetParent !== null);
  el?.click(); return !!el;
})()`);
const choose = (label, value) => page.eval(`(() => {
  const s = document.querySelector('select[aria-label=${JSON.stringify(label)}]');
  if (!s) return null;
  const option = [...s.options].find((o) => o.value === ${JSON.stringify(value)} || o.textContent.startsWith(${JSON.stringify(value)}));
  if (!option) return null;
  s.value = option.value; s.dispatchEvent(new Event("change", { bubbles: true }));
  return option.textContent;
})()`);
const menu = async (label) => {
  await page.press("More");
  await sleep(150);
  if (!(await clickText("[role=menuitem]", label))) throw new Error(`no ${label} in the menu`);
};

// 1. A new agent, in a new worktree, with a picture attached.
if (!(await clickText(".projects .row", "work"))) throw new Error("no work project");
await page.waitFor(`document.querySelector(".sessions .section-head")`);
await page.press("New session");
await page.waitFor(`document.querySelector(".new-agent select[aria-label='Works in']")`);
await page.waitFor(`[...document.querySelectorAll("select[aria-label='Works in'] option")].some((o) => o.value === "new")`, 15_000);
say(`works in: ${await choose("Works in", "new")}`);
await page.waitFor(`document.querySelector(".new-agent .menus") || document.querySelector(".new-agent .failure")`, 60_000);
say(`runtime: ${await page.eval(`document.querySelector("select[aria-label=Runtime]").selectedOptions[0].textContent`)}; menus: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".new-agent .menus select, .new-agent .menus button")].map((x) => x.getAttribute("aria-label") ?? x.textContent)`))}`);
await page.setFiles(".new-agent input[type=file]", [picture]);
await page.waitFor(`document.querySelector(".attachments li")`, 10_000);
say(`attached: ${JSON.stringify(await page.text(".attachments"))}`);
await page.focus(".new-agent textarea[aria-label=Prompt]");
await page.type("Say in one sentence what colour the attached picture is. Then run this with your Bash tool: echo one > one.txt. Then run this with your Bash tool: echo two > two.txt. Then say done.");
await page.shot(`${out}/us3-1-new.png`);
await page.press("Send");
await page.waitFor(`location.hash.includes("/s/")`, 60_000);
const id = await page.eval(`decodeURIComponent(location.hash.split("/s/")[1].split("/")[0])`);
const started = await until("the agent on the record", () => record(id));
say(`started ${id} from the browser: worktree ${started.worktree?.name ?? "none"} (${started.worktree?.branch ?? "-"}), cwd ${started.cwd}`);
const first = (await op.link.call("agents/transcript", { agentID: id, limit: 20 }, host)).entries.find((e) => e.kind.userMessage);
say(`its first prompt's blocks: ${JSON.stringify((first?.kind.userMessage.blocks ?? []).map((b) => b.type))}`);
window("open", id);
window("shot", `${out}/us3-window-1-started.png`);

// 2. A second prompt queued while the turn waits on its permission, then Send now.
await page.waitFor(`document.querySelector(".card[aria-label='Permission request']")`, 180_000);
await page.focus(".chat textarea[aria-label=Prompt]");
await page.type("Also, say the word banana.");
await page.press("Send");
await page.waitFor(`document.querySelector(".queued")`, 20_000);
await page.shot(`${out}/us3-2-queued.png`);
const queuedOnRecord = (await record(id)).queuedPrompts?.length ?? 0;
const sendNow = await page.eval(`!!document.querySelector(".queued button.link")`);
say(`queued: ${queuedOnRecord} on the record; Send now offered: ${sendNow}`);
if (sendNow) {
  await clickText(".queued button", "↑ Send now");
  await until("the queue to empty", async () => ((await record(id)).queuedPrompts?.length ?? 0) === 0, 30);
  say("Send now: the queue emptied on the record");
}
window("shot", `${out}/us3-window-2-queued.png`);
// The permission question holds the runtime: the rest happens while it waits on it.

// 3. The model, changed from the prompt's menu.
await page.waitFor(`document.querySelector(".chat .menus select[aria-label=Model]")`, 30_000);
const before = (await record(id)).startOptions.values.model;
const options = await page.eval(`[...document.querySelector(".chat select[aria-label=Model]").options].map((o) => o.textContent)`);
const current = await page.eval(`document.querySelector(".chat select[aria-label=Model]").selectedOptions[0]?.textContent`);
const other = options.find((o) => o !== current && o !== "");
say(`model menu: ${JSON.stringify(options)}, on ${current}; choosing ${other}`);
await choose("Model", other);
const changed = await until("the model on the record", async () => {
  const value = (await record(id)).startOptions.values.model;
  return JSON.stringify(value) !== JSON.stringify(before) ? value : null;
}, 30);
say(`model on the record: ${JSON.stringify(before)} → ${JSON.stringify(changed)}`);
await page.shot(`${out}/us3-3-model.png`);
window("shot", `${out}/us3-window-3-model.png`);

// 4. Park, unpark, stop and archive (and bring it back).
await until("the turn to hold its runtime", async () => ["running", "waitingOnUser"].includes((await record(id)).state), 60);
await menu("Park");
const parked = await until("parking", async () => (await record(id)).parking, 15);
say(`Park while it runs: ${JSON.stringify(parked)}`);
await menu("Unpark");
await until("unparked", async () => !(await record(id)).parking, 15);
say("Unpark: no parking on the record");
await menu("Stop");
const stopped = await until("stopped", async () => { const a = await record(id); return a.state === "stopped" ? a : null; }, 30);
say(`Stop: ${stopped.state}, ${stopped.endedReason}`);
await sleep(500);
say(`the waiting card after Stop: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".card")].map((c) => c.querySelector(".strong")?.textContent + " / " + (c.querySelector(".answered")?.textContent ?? "waiting"))`))}`);
await page.shot(`${out}/us3-4-stopped.png`);
window("shot", `${out}/us3-window-4-stopped.png`);
await menu("Archive");
await until("archived", async () => (await record(id)).state === "archived", 15);
say("Archive: archived on the record");
await page.shot(`${out}/us3-5-archived.png`);
await menu("Bring Back");
await until("brought back", async () => (await record(id)).state !== "archived", 15);
say(`Bring Back: ${(await record(id)).state}`);

// 5. A label added, then removed.
await page.focus(".labels .label-field");
await page.type("walked,");
await until("the label", async () => (await record(id)).labels?.some((l) => l.value === "walked"), 15);
await sleep(300);
await page.shot(`${out}/us3-6-label.png`);
window("shot", `${out}/us3-window-6-label.png`);
say(`label added: ${JSON.stringify((await record(id)).labels)}`);
await page.press("Remove the label walked");
await until("the label gone", async () => !(await record(id)).labels?.some((l) => l.value === "walked"), 15);
say("label removed: none on the record");

say(`problems shown: ${JSON.stringify(await page.eval(`document.querySelector(".problem")?.textContent ?? null`))}`);
say(`page errors: ${JSON.stringify(page.errors)}`);
writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
op.stop();
await chrome.close();
