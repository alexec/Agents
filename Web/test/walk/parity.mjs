// The parity walk (#110): the page beside the window, a scene for each change made to the
// window or the Remote since 071 was planned. Screenshots each scene and notes what the page
// shows, for specs/071-web-remote/walks/parity.md.
//
//   node Web/test/walk/parity.mjs <WEB_URL> <browser code> <ROOT> <out dir> <prefix> [scene…]
//
// The code is a browser's (`agents-control code --client --browser`). The root is a
// run-app scratch root seeded as parity.md says: a git project `work`, three workflows (one
// turned off), a finished unread session "Repo notes", one in a worktree with two labels, and
// one parked. Scenes that need the host away pause the root's own agentsd (its daemon.lock pid)
// with SIGSTOP and always resume it.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out, prefix, ...wanted] = process.argv.slice(2);
const scenes = wanted.length ? wanted : ["sessions", "chat", "workflow", "changes", "acting", "hostdown"];
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const daemon = readFileSync(`${root}/daemon.lock`, "utf8").trim();
const signal = (name) => execFileSync("kill", [`-${name}`, daemon]);

const chrome = await launch({ profile: `/tmp/110-parity-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

const shot = async (name) => {
  await sleep(300);
  await page.shot(`${out}/${prefix}-${name}.png`);
  say(`shot ${prefix}-${name}.png`);
};
const clickRow = (scope, text) => page.eval(`(() => {
  const row = [...document.querySelectorAll(${JSON.stringify(scope)} + " .row")]
    .find((r) => r.querySelector(".title")?.textContent.includes(${JSON.stringify(text)}) && r.offsetParent !== null);
  (row?.querySelector(".pick") ?? row)?.click();
  return !!row;
})()`);
const openProject = async () => {
  await clickRow(".projects", "work");
  await page.waitFor(`document.querySelector(".sessions .row.session")`, 30_000);
};
const openSession = async (title) => {
  if (!(await clickRow(".sessions", title))) throw new Error(`no session called ${title}`);
  await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
  await sleep(500);
};
const visible = (selector) => page.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})]
  .filter((el) => el.offsetParent !== null).map((el) => el.innerText.replace(/\\s+/g, " ").trim())`);

for (const scene of scenes) {
  say(`— ${scene}`);
  try {
    if (scene === "sessions") {
      // #70 unread, #68 worktree beside labels, sessions column, Archived folds, #100 off in place.
      await openProject();
      await page.waitFor(`document.querySelector(".workflows .row")`, 30_000);
      say(`rows: ${JSON.stringify(await visible(".sessions .row.session"))}`);
      say(`headings: ${JSON.stringify(await visible(".sessions .subhead"))}`);
      say(`workflows: ${JSON.stringify(await visible(".workflows .row"))}`);
      say(`project row: ${JSON.stringify(await visible(".projects .row.project"))}`);
      say(`project row height: ${await page.eval(`document.querySelector(".projects .row.project").getBoundingClientRect().height`)}`);
      await shot("sessions");
    } else if (scene === "asker") {
      // #121: a question or permission card names who asks, by title and runtime. Takes the
      // first session waiting on a card, so a root with one agent asking is enough.
      await openProject();
      await page.eval(`document.querySelector(".sessions .row.session .pick, .sessions .row.session")?.click()`);
      await page.waitFor(`document.querySelector(".cards .card")`, 30_000);
      say(`asker: ${JSON.stringify(await visible(".cards .card .asker"))}`);
      say(`card: ${JSON.stringify(await visible(".cards .card .strong"))}`);
      await shot("asker");
    } else if (scene === "chat") {
      // 069 turn detail, concise turns, trailing reply; #108 bar.
      await openProject();
      await openSession("Repo notes");
      say(`turns: ${JSON.stringify(await visible(".chat .turn"))}`);
      await shot("chat-outcome");
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "steps"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
      await shot("chat-steps");
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "outcome"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
    } else if (scene === "margin") {
      // #112: a turn's steps are a run of lines with no chevron; a step still opens. Takes the
      // first session, so a root with one finished turn is enough.
      await openProject();
      await page.eval(`document.querySelector(".sessions .row.session .pick, .sessions .row.session")?.click()`);
      await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "steps"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
      await sleep(300);
      say(`chevrons in the margin: ${await page.eval(`document.querySelectorAll(".turn .call-line .chevron").length`)}`);
      await page.eval(`(() => {
        const lines = [...document.querySelectorAll(".turn button.call-line")];
        (lines.find((b) => b.textContent.includes("Read file")) ?? lines[0])?.click();
      })()`);
      say(`opened: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".turn button.call-line[aria-expanded=true]")].map((b) => b.textContent)`))}`);
      await shot("margin");
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "outcome"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
    } else if (scene === "call") {
      // #153: an open call's detail as the window's: an edit's diff with + and − lines, Show in
      // Changes under it, and each location a link that opens the file. Takes the first session,
      // so a root with one turn that read a file and edited another is enough.
      await openProject();
      await page.eval(`document.querySelector(".sessions .row.session .pick, .sessions .row.session")?.click()`);
      await page.waitFor(`document.querySelector(".chat .turn")`, 30_000);
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "details"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
      await page.waitFor(`document.querySelector(".call-detail")`, 30_000);
      await page.eval(`document.querySelector(".call-detail .edit, .call-detail .diff")?.scrollIntoView({ block: "center" })`);
      say(`call: ${JSON.stringify(await page.eval(`(() => {
        const edit = document.querySelector(".call-detail .edit, .call-detail .diff");
        return {
          path: edit?.querySelector(".path, .quiet")?.textContent ?? null,
          diffLines: [...(edit?.querySelectorAll(".diff-line") ?? [])].map((l) => l.textContent),
          struckBlocks: edit?.querySelectorAll("pre.removed, pre.added").length ?? 0,
          showInChanges: [...document.querySelectorAll(".call-detail button")].some((b) => b.textContent === "Show in Changes"),
          locations: [...document.querySelectorAll(".call-detail .locations")].map((p) => ({
            text: p.innerText, links: p.querySelectorAll("button").length, font: getComputedStyle(p).fontFamily.split(",")[0],
          })),
        };
      })()`))}`);
      await shot("call-details");
      const showed = await page.eval(`(() => {
        const b = [...document.querySelectorAll(".call-detail button")].find((b) => b.textContent === "Show in Changes");
        b?.click(); return !!b;
      })()`);
      if (showed) {
        await page.waitFor(`document.querySelector(".files .changes .row.changed.chosen") && document.querySelector(".files .diff-line")`, 30_000);
        say(`show in changes: ${JSON.stringify(await page.eval(`({
          tab: document.querySelector(".files .tab.chosen")?.textContent,
          chosen: document.querySelector(".files .row.changed.chosen .title")?.textContent,
          lines: [...document.querySelectorAll(".files .diff-line")].map((l) => l.textContent),
        })`))}`);
        await shot("call-show-in-changes");
      }
      const opened = await page.eval(`(() => {
        const b = document.querySelector(".call-detail .locations button"); b?.click(); return b?.textContent ?? null;
      })()`);
      if (opened) {
        await page.waitFor(`document.querySelector(".files .file pre.file-text, .files .file .file-page")`, 30_000);
        say(`location ${opened}: ${JSON.stringify(await page.eval(`({
          tab: document.querySelector(".files .tab.chosen")?.textContent,
          file: document.querySelector(".files .file .crumbs .title")?.textContent,
        })`))}`);
        await shot("call-location");
      }
      await page.eval(`(() => { const s = document.querySelector("select.detail"); s.value = "outcome"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
    } else if (scene === "workflow") {
      // #98 triggers, next run, last fired; #100 Enabled switch and Turn Off/On.
      await openProject();
      await page.waitFor(`document.querySelector(".workflows .row")`, 30_000);
      const opened = await clickRow(".workflows", "After the build");
      await sleep(500);
      say(`a workflow row opens a page: ${opened && await page.eval(`!!document.querySelector(".workflow-page")`)}`);
      if (await page.eval(`!!document.querySelector(".workflow-page")`)) {
        say(`page: ${JSON.stringify(await visible(".workflow-page h1, .workflow-page .happening, .workflow-page .trigger, .workflow-page .last-ran"))}`);
        await shot("workflow-triggering");
        await clickRow(".workflows", "Write a greeting");
        await sleep(500);
        say(`page: ${JSON.stringify(await visible(".workflow-page h1, .workflow-page .happening, .workflow-page .trigger, .workflow-page .last-ran"))}`);
        await shot("workflow-schedule");
        await clickRow(".workflows", "Nightly tidy");
        await sleep(500);
        say(`page: ${JSON.stringify(await visible(".workflow-page h1, .workflow-page .happening, .workflow-page .trigger"))}`);
        await shot("workflow-off");
      } else {
        await shot("workflow");
      }
      // Turn Off/On, in the row's menu where the page has one.
      const menu = await page.eval(`(() => {
        const row = [...document.querySelectorAll(".workflows .row")].find((r) => r.textContent.includes("Write a greeting"));
        const more = row?.querySelector("[aria-label^='More']");
        more?.click();
        return !!more;
      })()`);
      await sleep(200);
      say(`workflow row menu: ${menu ? JSON.stringify(await visible(".workflows [role=menu] [role=menuitem]")) : "none"}`);
      if (menu) {
        await shot("workflow-menu");
        // Off and on again, through the host: the row is marked in place each way.
        const row = () => visible(".workflows .row.workflow");
        await page.press("Turn Off");
        await page.waitFor(`[...document.querySelectorAll(".workflows .row")].some((r) => r.textContent.includes("Write a greeting · Off"))`);
        say(`turned off: ${JSON.stringify((await row()).filter((r) => r.includes("Write a greeting")))}`);
        await page.eval(`[...document.querySelectorAll(".workflows .row")].find((r) => r.textContent.includes("Write a greeting")).querySelector("[aria-label^='More']").click()`);
        await sleep(200);
        await page.press("Turn On");
        await page.waitFor(`![...document.querySelectorAll(".workflows .row")].some((r) => r.textContent.includes("Write a greeting · Off"))`);
        say(`turned on: ${JSON.stringify((await row()).filter((r) => r.includes("Write a greeting")))}`);
      }
    } else if (scene === "filters") {
      // 073: a trigger's filters in words, lists as capsules joined by |, a wrong value named.
      await openProject();
      await page.waitFor(`document.querySelector(".workflows .row")`, 30_000);
      for (const [title, name] of [["Bug write-up", "filters-t1"], ["Done or nothing", "filters-list"],
        ["Failures and archives", "filters-codes"], ["Typo", "filters-typo"]]) {
        await clickRow(".workflows", title);
        await sleep(500);
        say(`${title}: ${JSON.stringify(await visible(".workflow-page h1, .workflow-page .heading p, .workflow-page .trigger"))}`);
        await shot(name);
      }
    } else if (scene === "startsoff") {
      // #124: a workflow that started off says why, an agent's and a file's.
      await openProject();
      await page.waitFor(`document.querySelector(".workflows .row")`, 30_000);
      for (const [title, name] of [["Nightly check", "startsoff-agent"], ["Weekly review", "startsoff-file"]]) {
        await clickRow(".workflows", title);
        await sleep(500);
        say(`${title}: ${JSON.stringify(await visible(".workflow-page h1, .workflow-page .happening"))}`);
        await shot(name);
      }
    } else if (scene === "changes") {
      // #63 Changes as a tree with status colours; Files as the same rows; #66 Back with the file marked.
      await openProject();
      await openSession("Repo notes");
      await page.press("Files");
      await page.waitFor(`document.querySelector("aside.files")`);
      const tab = (name) => page.eval(`[...document.querySelectorAll("aside.files [role=tab]")].find((t) => t.textContent === ${JSON.stringify(name)})?.click()`);
      await tab("Changes");
      await sleep(1000);
      say(`changes: ${JSON.stringify(await visible("aside.files .changes .row"))}`);
      await shot("changes");
      await tab("Files");
      await sleep(1000);
      say(`files: ${JSON.stringify(await visible("aside.files .entries .row"))}`);
      await shot("files");
      await clickRow("aside.files", "notes.md");
      await sleep(800);
      await page.eval(`document.querySelector("aside.files .crumbs button")?.click()`);
      await sleep(800);
      say(`back: marked ${JSON.stringify(await visible("aside.files .row.chosen, aside.files .row.marked"))}`);
      await shot("files-back");
      await page.eval(`document.querySelector("[aria-label='Close Files']")?.click()`);
    } else if (scene === "acting") {
      // #87: in-flight marks, one action at a time, with the host paused so they last.
      await openProject();
      await openSession("Repo notes");
      signal("STOP");
      try {
        await page.eval(`document.querySelector(".session-menu > button").click()`);
        await sleep(200);
        await page.press("Park");
        await sleep(600);
        say(`row while parking: ${JSON.stringify(await visible(".sessions .row.session.chosen"))}`);
        say(`menu while parking: ${await page.eval(`document.querySelector(".session-menu > button").disabled`)}`);
        await page.focus(".chat textarea");
        await page.type("One more line, please.");
        await page.eval(`document.querySelector(".chat button.send").click()`);
        await sleep(800);
        say(`bar while sending: ${JSON.stringify(await visible(".chat .foot .telling, .chat .foot button.send"))}`);
        await shot("acting");
      } finally {
        signal("CONT");
      }
      await sleep(3000);
      say(`after: ${JSON.stringify(await visible(".sessions .row.session"))}`);
      // Unpark, so the session is as it was.
      await page.eval(`document.querySelector(".session-menu > button").click()`);
      await sleep(200);
      await page.press("Unpark").catch(() => {});
    } else if (scene === "starting") {
      // #87: a new session's words stay, held, under "Starting — telling your Mac".
      await openProject();
      await page.eval(`document.querySelector(".sessions [aria-label='New session']").click()`);
      await page.waitFor(`document.querySelector(".new-agent .menus")`, 60_000);
      signal("STOP");
      try {
        await page.focus(".new-agent textarea");
        await page.type("Reply with one word: started.");
        await page.eval(`document.querySelector(".new-agent button.send").click()`);
        await sleep(800);
        say(`while starting: ${JSON.stringify(await visible(".new-agent .telling"))}, field ${JSON.stringify(await page.eval(`(() => { const t = document.querySelector(".new-agent textarea"); return { text: t.value, readOnly: t.readOnly }; })()`))}`);
        await shot("starting");
      } finally {
        signal("CONT");
      }
      await page.waitFor(`document.querySelector(".chat .transcript")`, 60_000).catch(() => {});
      say(`after: opened ${JSON.stringify(await visible(".chat .column-head h1"))}`);
    } else if (scene === "identity") {
      // #111: the footer names the browser, and no grant.
      say(`footer: ${JSON.stringify(await page.text(".identity"))}`);
      await shot("identity");
    } else if (scene === "hostdown") {
      // #83: the host down is plain and said at once.
      await openProject();
      await openSession("Repo notes");
      signal("STOP");
      const pausedAt = Date.now();
      try {
        await page.waitFor(`document.querySelector(".offline-strip")`, 90_000).catch(() => {});
        say(`said after ${((Date.now() - pausedAt) / 1000).toFixed(1)} s: ${JSON.stringify(await visible(".offline-strip, .projects .offline, .projects .host-down"))}`);
        await shot("hostdown-chat");
        await page.eval(`document.querySelector(".sessions [aria-label='New session']").click()`);
        await sleep(600);
        say(`new session: ${JSON.stringify(await visible(".offline-strip"))}`);
        await shot("hostdown-new");
      } finally {
        signal("CONT");
      }
      await page.waitFor(`!document.querySelector(".offline-strip")`, 90_000).catch(() => {});
      say(`back after ${((Date.now() - pausedAt) / 1000).toFixed(1)} s`);
    }
  } catch (error) {
    say(`${scene} failed: ${error.message}`);
  }
  await page.goto(webURL);
  await page.waitFor(`document.querySelector(".projects .row")`, 30_000);
}

say(`errors: ${JSON.stringify(page.errors)}`);
appendFileSync(`${out}/${prefix}-notes.txt`, notes.join("\n") + "\n");
await chrome.close();
