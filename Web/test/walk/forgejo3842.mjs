// The #3842 walk: Retry on the forgejo server's views on the web page, against a scratch Forgejo
// in a container whose pull request's Actions run failed. Pairs, opens the folder's pinned Pull
// requests, presses Retry on the row, waits for the run to fail again, then opens the pull
// request's page, its Checks tab, and presses Retry Failed Jobs.
//
//   node Web/test/walk/forgejo3842.mjs <WEB_URL> <browser code> <folder name> <pr number> <out dir>
//
// Expects the folder's .agents/pins.json to pin ui://forgejo/pull-requests, and its forgejo
// server approved. The run's failed jobs must fail again within a minute.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, name, number, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
// One profile for every run, so a browser the window approved once stays in the lock.
const chrome = await launch({ profile: "/tmp/run-fj3842-chrome" });

/** The session of the frame whose document's title is `title`: a view, inside its sandbox proxy. */
const viewFrame = async (title, timeout = 20_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const { targetInfos } = await chrome.send("Target.getTargets");
    for (const t of targetInfos.filter((t) => t.type === "iframe")) {
      const { sessionId } = await chrome.send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
      const { result } = await chrome.send("Runtime.evaluate", { expression: "document.title", returnByValue: true }, sessionId);
      if (result.value === title) return sessionId;
    }
    // A view in the proxy's own process is not a target of its own: look in each frame's world.
    await sleep(300);
  }
  throw new Error(`no view frame titled ${title}`);
};
const inView = async (session, expression) => {
  const { result, exceptionDetails } = await chrome.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, session);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  return result.value;
};
const waitInView = async (session, expression, timeout = 15_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await inView(session, `Boolean(${expression})`).catch(() => false)) return;
    await sleep(100);
  }
  throw new Error(`waited ${timeout} ms in the view for ${expression}`);
};
const pressInView = (session, words) => inView(session, `(() => {
  const b = [...document.querySelectorAll("button, a")].find((b) => b.textContent.trim().startsWith(${js(words)}));
  if (!b) return false;
  b.click();
  return true;
})()`);

const page = await chrome.page(webURL, { width: 1440, height: 900 });
try {
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
    await sleep(2000);
  }
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 15 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await sleep(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  }
  await page.waitFor(`document.querySelectorAll(".sidebar .row.folder").length >= 1`, 20_000);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && b.getAttribute("aria-expanded") !== "true") b.click();
  })()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.pin").length >= 1`, 10_000);
  await page.eval(`[...document.querySelectorAll(".sidebar .row.pin")].find((r) => r.querySelector(".title").textContent === "Pull requests").querySelector(".pick").click()`);
  await page.waitFor(`document.querySelector(".view-layer iframe")`, 15_000);
  await sleep(800);
  if (await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Show")`)) await page.press("Show");
  const pulls = await viewFrame("Pull requests");
  const row = `[...document.querySelectorAll("#prs li:not(.section)")].find((li) => li.querySelector("a")?.textContent === "#" + ${js(number)})`;
  const retryOnRow = `${row}?.querySelector(".pills button")`;
  await waitInView(pulls, retryOnRow);
  check(await inView(pulls, `${retryOnRow}.textContent === "Retry"`), "a pull request whose checks failed has Retry on its row");
  await sleep(400);
  await page.shot(`${out}/web-pulls-retry.png`);

  // Retry: the row's run is sent again, and the list is read again.
  await inView(pulls, `${retryOnRow}.click()`);
  await waitInView(pulls, `!${retryOnRow} || ${retryOnRow}.textContent === "Retry"`, 20_000);
  const after = await inView(pulls, `${row}.textContent.replace(/\\s+/g, " ").trim()`);
  check(!/error|Couldn/.test(after), `Retry ran the failed jobs again: ${js(after)}`);
  await page.shot(`${out}/web-pulls-retried.png`);

  // The run fails again; then a pull request's page, its Checks tab.
  await sleep(45_000);
  await pressInView(pulls, "Refresh");
  await waitInView(pulls, retryOnRow, 30_000);
  check(await inView(pulls, `(() => { const a = ${row}?.querySelector("a.title"); a?.click(); return !!a; })()`), `#${number}'s title opens its page`);
  await waitInView(pulls, `document.querySelector("#page h2")`);
  await pressInView(pulls, "Checks");
  await waitInView(pulls, `[...document.querySelectorAll("#page button")].some((b) => b.textContent === "Retry Failed Jobs")`);
  check(true, "the Checks tab has Retry Failed Jobs");
  await sleep(400);
  await page.shot(`${out}/web-pr-checks-retry.png`);
  await pressInView(pulls, "Retry Failed Jobs");
  await waitInView(pulls, `document.querySelector("#page").textContent.includes("The failed jobs run again.")`, 15_000);
  check(true, "Retry Failed Jobs says the failed jobs run again");
  await sleep(1500);
  await page.shot(`${out}/web-pr-retried.png`);
  const errors = page.errors.filter((e) => !e.includes("favicon"));
  check(!errors.length, `no errors on the page: ${js(errors)}`);
} catch (e) {
  await page.shot(`${out}/failed.png`).catch(() => {});
  throw e;
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
