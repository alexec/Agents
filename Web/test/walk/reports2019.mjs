// The #2019 walk: Reports ▸ Outcomes, Time, Runtimes, Adoption and Workflows on a scratch control plane whose store holds
// synthetic days with counts (never a real record). Opens each page, checks the totals' words,
// and shoots each at <out dir>.
//
//   node Web/test/walk/reports2019.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

const chrome = await launch({ profile: `/tmp/run-r2019-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  for (const [section, words] of [["outcomes", "merged of"], ["time", "Waiting for a person"], ["runtimes", "sessions failed"],
    ["adoption", "active person"], ["workflows", "runs failed"]]) {
    await page.eval(`location.hash = "#/reports/${section}"`);
    await page.waitFor(`document.querySelector(".report-list")?.textContent.includes(${JSON.stringify(words)})`, 20_000);
    const said = (await page.text(".reports-pane")).replace(/\s+/g, " ");
    console.log(said.slice(0, 600));
    check(said.includes(words), `${section} draws its totals`);
    await page.shot(`${out}/web-${section}.png`);
  }
  await page.eval(`location.hash = "#/reports/time"`);
  await page.waitFor(`document.querySelector(".report-list")?.textContent.includes("Waiting")`, 20_000);
  await page.press("3M");
  await page.press("Runtime");
  await page.waitFor(`document.querySelector(".report-list")?.textContent.includes("Codex")`, 20_000);
  check(true, "Time by runtime over 3M");
  await page.shot(`${out}/web-time-runtime.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
