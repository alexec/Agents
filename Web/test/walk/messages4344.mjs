// Messages (#4344), on a run-app root whose folder has two scratch servers that follow the messaging
// contract (a Slack one and an Email one): the bar has Messages after Docs; the list is both
// connectors' conversations, the newest first, with unread counts; Source keeps one service's;
// Unread keeps the unread ones; a conversation opens to its messages, as plain text. With
// --empty, the root has no messaging connector, and the page says so with Open Connectors.
// Screenshots into <out dir>.
//
//   node Web/test/walk/messages4344.mjs <WEB_URL> <browser code> <out dir> [--empty]

import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, mode] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-msg4344-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const shot = async (name) => { await scrub(); await page.shot(`${out}/${name}.png`); };

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  const bar = await text(".nav-item");
  ok(`Messages after Docs in the bar: ${bar.join(" | ")}`, bar.indexOf("Messages") === bar.indexOf("Docs") + 1);
  await page.eval(`location.hash = "#/messages"`);

  if (mode === "--empty") {
    await page.waitFor(`(document.querySelector(".messages-list button.link")?.click(), !!document.querySelector(".messages-empty"))`, 120_000);
    // The folders were read before the window approved this browser: read them again.
    await page.eval(`location.reload()`);
    await page.waitFor(`!!document.querySelector(".messages-empty button")`, 60_000);
    ok("no connector: Open Connectors", (await text(".messages-empty button")).includes("Open Connectors"));
    await shot("web-no-connector");
  } else {
    // A new browser joins the person's lock: approve it in the window, then Refresh (the walk waits).
    await page.waitFor(`(document.querySelector(".messages-list button.link")?.click(), document.querySelectorAll(".messages-row").length >= 5)`, 120_000);
    await sleep(500);
    const titles = await text(".messages-row .messages-title");
    ok(`newest first: ${titles.join(" | ")}`, titles.join("|") === "#release|Invoice for October|Sam Rivera|#design|Re: Offsite plans");
    await shot("web-list");

    await page.eval(`(() => { const s = document.querySelector(".messages-list select"); s.value = "email"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
    await sleep(300);
    ok(`Source keeps Email's: ${(await text(".messages-row .messages-title")).join(" | ")}`, (await text(".messages-row")).length === 2);
    await shot("web-source");
    await page.eval(`(() => { const s = document.querySelector(".messages-list select"); s.value = ""; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);

    await page.eval(`document.querySelector(".messages-list input[type=checkbox]").click()`);
    await page.waitFor(`document.querySelectorAll(".messages-row").length === 2`, 30_000);
    await shot("web-unread");
    await page.eval(`document.querySelector(".messages-list input[type=checkbox]").click()`);
    await page.waitFor(`document.querySelectorAll(".messages-row").length >= 5`, 30_000);

    await page.eval(`[...document.querySelectorAll(".messages-row")].find((b) => b.textContent.includes("#release")).click()`);
    await page.waitFor(`document.querySelectorAll(".messages-message").length === 3`, 30_000);
    const bodies = await text(".messages-text");
    ok(`plain text, not markup: ${bodies[1]}`, bodies[1].includes("<b>not markup</b>"));
    ok(`the address is the conversation's: ${await page.eval("location.hash")}`, (await page.eval("location.hash")) === "#/messages/slack%3AC01");
    await shot("web-conversation");
  }
} catch (e) {
  await shot("web-failed");
  throw e;
} finally {
  await chrome.close();
}
