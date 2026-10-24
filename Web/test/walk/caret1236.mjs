// The #1236 walk: the agent's caret on a live page on the web, as the window has it. Pairs, opens
// a folder's pinned Markdown page, appends two passages to its file, and reads the page while
// the caret types them: a part of the first with the caret after it, the second not there yet,
// then both whole and no caret. Fails on any error the page throws.
//
//   node Web/test/walk/caret1236.mjs <WEB_URL> <browser code> <folder> <folder name> <pin title> <out dir>

import { appendFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folder, name, title, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1236-caret-chrome-${process.pid}` });

const first = "The agent's caret types this passage at two hundred characters a second, eight at a time. ".repeat(4).trim();
const second = "A second passage waits its turn, in document order.";

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 10_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin .pick")].find((b) => b.querySelector(".title").textContent === ${js(title)}).click()`);
  await page.waitFor(`document.querySelector(".pinned-page .live-page .page h1")`, 10_000);
  await sleep(500);

  appendFileSync(`${folder}/page.md`, `\n${first}\n\n${second}\n`);
  await page.waitFor(`document.querySelector(".passage.typing")`, 10_000);
  await sleep(300);
  const typing = await page.eval(`(() => {
    const p = document.querySelector(".passage.typing");
    const last = p.querySelector(".markdown > :last-child") ?? p.querySelector(".markdown");
    return { text: p.innerText, busy: p.getAttribute("aria-busy"), caret: getComputedStyle(last, "::after").content,
      page: document.querySelector(".pinned-page .live-page").innerText };
  })()`);
  check(typing.text.length > 0 && typing.text.length < first.length, `part of the first passage typed: ${typing.text.length} of ${first.length}`);
  check(typing.caret.includes("▍"), `the caret is after it: ${typing.caret}`);
  check(typing.busy === "true", "the passage says it is busy");
  check(!typing.page.includes(second), "the second passage is not on the page yet");
  await page.shot(`${out}/web-1236-1-typing.png`);

  // About 410 characters at 200 a second: about 2 s for both.
  await page.waitFor(`!document.querySelector(".passage.typing")`, 10_000);
  const done = await page.eval(`document.querySelector(".pinned-page .live-page").innerText`);
  check(done.includes(first) && done.includes(second), "both passages whole once the caret is done");
  await page.shot(`${out}/web-1236-2-done.png`);
  // Chrome's note that the pairing form's autofocus lost to the focused field is not the page's.
  const errors = page.errors.filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `page errors: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
