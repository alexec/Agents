// The #2019 walk of saved views (R8) on a scratch control plane with synthetic days: Save View…
// on Outcomes by Folder over M, then Reports ▸ Saved Views lists it, Open brings back its range and
// way, Copy Digest copies its numbers (a refused copy says so), and Delete… asks, then takes it away. Shots go to <out dir>.
//
//   node Web/test/walk/views2019.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".reports-pane")`;
const on = (label) => `[...document.querySelectorAll("[role=radio][aria-checked=true]")].some((b) => b.textContent === ${JSON.stringify(label)})`;

const chrome = await launch({ profile: `/tmp/run-r2019-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/reports/outcomes"`);
  await page.waitFor(`${pane}?.textContent.includes("merged of")`, 20_000);
  await page.press("M");
  await page.press("Folder");
  await page.press("Save View…");
  await page.focus("input[aria-label='View name']");
  await page.type("Monday digest");
  await page.press("Save");
  await page.waitFor(`${pane}.textContent.includes("It is in Reports ▸ Saved Views")`, 10_000);
  check(true, "Save View… saved it");

  await page.eval(`location.hash = "#/reports/saved"`);
  await page.waitFor(`${pane}?.textContent.includes("Monday digest")`, 10_000);
  const said = (await page.text(".reports-pane")).replace(/\s+/g, " ");
  check(said.includes("Outcomes · Me · The last 30 days · By Folder"), `Saved lists it: ${said.slice(0, 200)}`);
  await page.shot(`${out}/web-saved.png`);

  await page.eval(`(async () => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent === "Copy Digest"); b.click(); })()`);
  await page.waitFor(`[...document.querySelectorAll("button")].some((x) => x.textContent === "Copied") || document.querySelector(".reports-pane .hint")`, 10_000);
  const copied = await page.eval(`[...document.querySelectorAll("button")].some((x) => x.textContent === "Copied")`);
  check(copied, "Copy Digest copied");
  // A refused write (Safari, after an await) says so, not that the control plane is down (#2263).
  await page.eval(`navigator.clipboard.write = navigator.clipboard.writeText = () => Promise.reject(new DOMException("refused", "NotAllowedError"))`);
  await page.press("Copied");
  await page.waitFor(`document.querySelector(".reports-pane .hint")`, 10_000);
  const refused = await page.text(".reports-pane .hint");
  check(refused.startsWith("Couldn’t copy."), `a refused copy: ${refused}`);

  await page.press("Open");
  await page.waitFor(`location.hash === "#/reports/outcomes" && ${on("M")} && ${on("Folder")}`, 10_000);
  check(true, "Open brings back M and By Folder on Outcomes");
  await page.shot(`${out}/web-opened.png`);

  await page.eval(`location.hash = "#/reports/saved"`);
  await page.waitFor(`${pane}?.textContent.includes("Monday digest")`, 10_000);
  // Delete… asks first (#2262): Cancel keeps the view, OK takes it away.
  await page.eval(`window.confirm = () => false`);
  await page.press("Delete…");
  check(await page.eval(`${pane}.textContent.includes("Monday digest")`), "Cancel on Delete… keeps it");
  await page.eval(`window.asked = ""; window.confirm = (m) => { window.asked = m; return true; }`);
  await page.press("Delete…");
  check((await page.eval(`window.asked`)).startsWith("Delete Monday digest?"), "Delete… asks by name");
  await page.waitFor(`${pane}.textContent.includes("No saved views yet")`, 10_000);
  check(true, "Delete takes it away");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
