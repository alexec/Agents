// The #1953 walk (SC-001 of #1480): the page on this Mac, served by this Mac's host while the
// control plane runs elsewhere. Pairs at the host's loopback page with a browser code, opens a
// session titled THIS (on this Mac's host) and one titled OTHER (on another host), and checks
// that each one's transcript is drawn. Fails on any error the page throws.
// With FREEZE_PID (the control plane's pid), the control plane is stopped (SIGSTOP) once the page is
// connected: this host's session must still open, answered here (FR-007), and the other's must not.
//
//   [FREEZE_PID=<pid>] node Web/test/walk/local1953.mjs <page URL> <browser code> <this title> <other title> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [pageURL, code, thisTitle, otherTitle, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const chrome = await launch({ profile: `/tmp/run-1953-chrome-${process.pid}` });

try {
  const page = await chrome.page(pageURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.shot(`${out}/web-1-pairing.png`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 2`, 30_000);
  await page.eval(`(() => {
    for (const b of document.querySelectorAll(".sidebar .row.folder .disclosure"))
      if (b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await sleep(1000);
  await page.shot(`${out}/web-2-paired.png`);
  const freeze = Number(process.env.FREEZE_PID || 0);
  if (freeze) process.kill(freeze, "SIGSTOP");
  let n = 3;
  for (const title of [thisTitle, otherTitle]) {
    const row = `[...document.querySelectorAll(".sidebar .row.session")].find((r) => r.textContent.includes(${js(title)}))`;
    const found = await page.waitFor(row, 20_000).then(() => true, () => false);
    check(found, `the sidebar lists ${js(title)}`);
    if (!found) continue;
    await page.eval(`${row}.click()`);
    const drawn = await page.waitFor(`document.body.innerText.includes("0: Seeded words")`, 20_000)
      .then(() => true, () => false);
    await page.shot(`${out}/web-${n++}-${freeze ? "frozen-" : ""}${title.split(" ")[0].toLowerCase()}.png`);
    const want = !freeze || title === thisTitle;
    check(drawn === want, `the transcript of ${js(title)} is ${drawn ? "" : "not "}drawn${freeze ? " with the control plane stopped" : ""}`);
    await page.eval(`history.back()`);
    await sleep(500);
  }
  check(page.errors.length === 0, `page errors: ${js(page.errors)}`);
} finally {
  if (Number(process.env.FREEZE_PID || 0)) process.kill(Number(process.env.FREEZE_PID), "SIGCONT");
  await chrome.close();
}
process.exit(failed ? 1 : 0);
