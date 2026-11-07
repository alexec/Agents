// The #3716 walk, on a scratch root with a stand-in Grok: New Session's ↺ pill opens the
// conversations the runtime holds in the folder and its other worktrees (one in a
// Conductor-like workspace says "in" and its name), and Pick up opens it as a session.
//
//   RECOVERY_KEY=… node Web/test/walk/sessions3716.mjs <WEB_URL> <browser code> <folder name> <runtime name> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, folder, runtime, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chrome = await launch({ profile: `/tmp/run-import-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(2000);
  // The browser joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
  if (await page.eval(`document.body.innerText.includes("Approve this device on another of your devices.")`)) {
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
    await page.eval(`location.reload()`);
    await sleep(2000);
  }
  await page.waitFor(`[...document.querySelectorAll(".row .title")].some((t) => t.textContent === ${JSON.stringify(folder)})`, 30_000);
  await page.eval(`[...document.querySelectorAll(".row.folder")].find((r) => r.querySelector(".title")?.textContent === ${JSON.stringify(folder)}).querySelector(".disclosure").click()`);
  // The session the window picked up is in it: its address names the host and the folder.
  await page.waitFor(`[...document.querySelectorAll(".row")].some((r) => r.offsetParent && !/folder|new-session|activity-row/.test(r.className))`, 20_000);
  await page.eval(`[...document.querySelectorAll(".row")].find((r) => r.offsetParent && !/folder|new-session|activity-row/.test(r.className)).click()`);
  await page.waitFor(`location.hash.includes("/s/")`);
  await page.eval(`location.hash = location.hash.replace(/\\/s\\/.*$/, "") + "/n/1"`);
  await page.waitFor(`document.querySelector(".new-agent select[aria-label=Runtime]")`, 30_000);
  // The stand-in runtime, not Auto: on Auto the pill is greyed.
  await page.eval(`(() => { const s = document.querySelector(".new-agent select[aria-label=Runtime]");
    const o = [...s.options].find((o) => o.textContent.startsWith(${JSON.stringify(runtime)}));
    s.value = o.value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelector(".new-agent .menus") || document.querySelector(".new-agent .failure") || document.querySelector(".new-agent .quiet.small")`, 60_000);
  await sleep(500);
  await page.shot(`${out}/web-new-session.png`);
  await page.press("Sessions");
  await page.waitFor(`document.querySelector("dialog.sheet[open] .runtime-session-list li") || document.querySelector("dialog.sheet[open] .failure") || document.body.innerText.includes("is holding nothing")`, 60_000);
  await sleep(300);
  console.log(JSON.stringify(await page.text("dialog.sheet")));
  await page.shot(`${out}/web-sessions.png`);
  await page.eval(`[...document.querySelectorAll("dialog.sheet .runtime-session-list li")].find((li) => /in workspace-/.test(li.textContent) && li.textContent.includes("Pick up")).querySelector("button").click()`);
  await page.waitFor(`!document.querySelector("dialog.sheet[open]")`, 60_000);
  await page.waitFor(`document.body.innerText.includes("two and two")`, 30_000);
  await sleep(800);
  await page.shot(`${out}/web-picked-up.png`);
  console.log("picked up:", await page.eval("location.hash"));
} catch (e) {
  console.log("failed:", e.message);
  throw e;
} finally {
  await chrome.close();
}
