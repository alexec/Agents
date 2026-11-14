// "From this device" says when it was read (#5142): on a run-app root whose folder is on the fixture GitHub
// (forge3268-github.py, AGENTS_TEST_GITHUB_URL), open epic #40 once so this device keeps it, stop the fixture so the
// next read hangs, wait past a minute, open #40 again: the page's one strip says "Last update 1 min ago". Then end the
// fixture so the read fails: the failure strip says it too. Screenshots into <out dir>, each named with <prefix>.
//
//   node Web/test/walk/lastupdate5142.mjs <WEB_URL> <browser code> <fixture pid> <out dir> [prefix]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, fixture, out, prefix = "web"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-lu5142-chrome` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const epic = `"#/work/issue/" + encodeURIComponent("github:example/shop#40")`;

try {
  // A profile paired by an earlier run is approved already.
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".nav-item")`, 30_000);
  if (await page.eval(`!document.querySelector(".nav-item")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
    await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  }

  // Read once: the item and its plan are kept on this device.
  // A new browser is one of the person's devices only once another approves it (the machine lock): approve it in the
  // window while this tries again.
  await page.eval(`location.hash = ${epic}`);
  for (let i = 0; i < 40; i++) {
    if (await page.eval(`document.querySelectorAll(".work-plan-row").length === 5`)) break;
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent === "Try again")?.click()`);
    await sleep(3000);
  }
  await page.waitFor(`document.querySelectorAll(".work-plan-row").length === 5`, 30_000);
  await sleep(2000);
  await page.eval(`location.hash = "#/work/issue"`);
  await sleep(1000);

  // The machine is asked again and does not answer: the copy, with when it was read.
  process.kill(Number(fixture), "SIGSTOP");
  await sleep(65_000);
  await page.eval(`location.hash = ${epic}`);
  await page.waitFor(`document.querySelector(".work-from-device")`, 15_000);
  const strips = await page.eval(`[...document.querySelectorAll(".work-from-device")].map((e) => e.textContent.trim())`);
  ok(`one strip: ${strips.join(" | ")}`, strips.length === 1 && strips[0].includes("Last update 1 min ago"));
  await page.shot(`${out}/${prefix}-item-from-device.png`);
  console.log(`shot ${out}/${prefix}-item-from-device.png`);

  // The read fails: the kept page stays, dimmed, and the failure strip says how old it is.
  process.kill(Number(fixture), "SIGKILL");
  await page.waitFor(`[...document.querySelectorAll(".message-banner")].some((e) => e.textContent.includes("Last update"))
    && !document.querySelector(".work-from-device")`, 30_000);
  await sleep(1000);
  await page.shot(`${out}/${prefix}-item-failed.png`);
} catch (e) {
  await page.shot(`${out}/${prefix}-error.png`);
  throw e;
} finally {
  await chrome.close();
}
