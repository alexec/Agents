// The #1501 walk: a control plane elsewhere, where this Mac's host joined with an id of its own,
// not `mac`. Pairs by a browser code, and checks that the page takes that host as This Mac: its
// folder is named alone in the sidebar, and a display choice made on the page goes to it
// (the walk reads the host's preferences/get itself afterwards).
// Fails on any error the page throws.
//
//   node Web/test/walk/mac1501.mjs <page URL> <browser code> <folder> <out dir> [chrome flag…]

import { launch } from "./cdp.mjs";

const [pageURL, code, folder, out, ...args] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/1501-chrome-${process.pid}`, args });

try {
  const page = await chrome.page(pageURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  const labels = await page.eval(`[...document.querySelectorAll(".sidebar .row.folder .disclosure")].map((b) => b.getAttribute("aria-label"))`);
  check(labels.some((l) => l.endsWith(` ${folder}`) && !l.includes(":")), `the folder is named alone, as This Mac's: ${js(labels)}`);
  await page.shot(`${out}/web-1-sidebar.png`);

  // A display choice: the first sidebar switch in Settings, which goes to the person's Mac.
  await page.press("Settings");
  await page.waitFor(`document.querySelector(".settings-page input[role=switch]")`, 10_000);
  const before = await page.eval(`[...document.querySelectorAll("#settings-sidebar ~ label input")].map((i) => i.checked)`);
  await page.eval(`document.querySelector("#settings-sidebar ~ label input").click()`);
  await new Promise((resolve) => setTimeout(resolve, 1500));
  const after = await page.eval(`[...document.querySelectorAll("#settings-sidebar ~ label input")].map((i) => i.checked)`);
  check(js(before) !== js(after), `the switch moved: ${js(before)} → ${js(after)}`);
  await page.shot(`${out}/web-2-settings.png`);
  // Chrome's note that the pairing field kept the focus is not the page's error.
  const errors = page.errors.filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `page errors: ${js(errors)}`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
