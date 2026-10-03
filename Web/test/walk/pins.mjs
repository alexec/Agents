// The #159 walk: a project's pinned pages on the web page, under the project in the sidebar and
// open in the chat's place. Pairs, unfolds the project, opens each pin, follows an edit, and
// drags the last pin to the top. Fails on any error the page throws.
//
//   node Web/test/walk/pins.mjs <WEB_URL> <browser code> <project folder> <project name> <out dir>
//
// Expects the project to have docs/roadmap.md, coverage/index.html (with a stylesheet beside it)
// and specs/review/README.md pinned, in that order, as /tmp/seed-pins159.sh leaves it.

import { appendFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, folder, name, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/159-pins-chrome-${process.pid}` });

try {
  const page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.project .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 3`, 10_000);
  const pins = () => page.eval(`[...document.querySelectorAll(".sidebar .row.pin .title")].map((t) => t.textContent)`);
  check(js(await pins()) === js(["Roadmap", "Coverage", "Security review"]), `pins under the project: ${js(await pins())}`);

  const open = (title) => page.eval(`[...document.querySelectorAll(".sidebar .row.pin .pick")].find((b) => b.querySelector(".title").textContent === ${js(title)}).click()`);
  await open("Roadmap");
  await page.waitFor(`document.querySelector(".pinned-page .live-page .page h1")`, 10_000);
  await sleep(500);
  check((await page.eval("location.hash")).includes("/pg/"), `the route names the page: ${await page.eval("location.hash")}`);
  await page.shot(`${out}/web-1-markdown-pin.png`);

  appendFileSync(`${folder}/docs/roadmap.md`, "\n## Added from the walk\n\nWritten while the page was open in the browser.\n");
  await page.waitFor(`document.querySelector(".pinned-page .live-page").innerText.includes("Added from the walk")`, 10_000);
  check(true, "the page followed an edit to its file");
  await page.shot(`${out}/web-2-followed-an-edit.png`);

  await open("Coverage");
  // The page's policy allows no frames, so HTML is its source here, as the files pane shows it.
  await page.waitFor(`document.querySelector(".pinned-page .page-source pre")`, 10_000);
  await sleep(300);
  check((await page.eval(`document.querySelector(".pinned-page .page-source pre").textContent`)).includes("<h1>Coverage</h1>"),
    "the HTML pin is shown as its source");
  await page.shot(`${out}/web-3-html-pin.png`);

  // Drag the last pin onto the first: HTML5 drag and drop, as a person's would be.
  await page.eval(`(() => {
    const items = [...document.querySelectorAll(".sidebar .group.pins .nav-item")];
    const from = items[items.length - 1], to = items[0];
    const data = new DataTransfer();
    from.dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer: data }));
    to.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: data }));
    to.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data }));
    from.dispatchEvent(new DragEvent("dragend", { bubbles: true, dataTransfer: data }));
  })()`);
  await sleep(1500);
  check(js(await pins()) === js(["Security review", "Roadmap", "Coverage"]), `dragged to the top: ${js(await pins())}`);
  await page.shot(`${out}/web-4-dragged.png`);
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
