// The #3898 walk: a click on a label's chip in the chat filters the sidebar by it, and a second
// click shows every session again. The browser joins the scratch root's lock with the recovery
// key its window showed (RECOVERY_KEY), as work3881.mjs does.
//
//   node Web/test/walk/label3898.mjs <WEB_URL> <browser code> <out dir> <session title> <label>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, title, label] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-label3898-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 800 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const rows = () => page.eval(`[...document.querySelectorAll(".sidebar .row.session .title")].map((r) => r.innerText)`);
const search = () => page.eval(`document.querySelector(".sidebar input.search").value`);
const chip = `[...document.querySelectorAll(".labels .chip button.filter")].find((b) => b.textContent === ${JSON.stringify(label)})`;
const asked = `document.body.innerText.includes("Approve this device")`;

/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
async function joinLock() {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
}

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await joinLock();
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 30_000);
  // The folder opens folded: unfold it.
  await page.eval(`document.querySelector(".sidebar .row.folder button.disclosure")?.click()`);
  await page.waitFor(`document.querySelector(".sidebar .row.session")`, 30_000);
  await sleep(800);
  ok(`the field names label: (${await page.eval(`document.querySelector(".sidebar input.search").placeholder`)})`,
    (await page.eval(`document.querySelector(".sidebar input.search").placeholder`)).includes("label:"));
  await page.eval(`[...document.querySelectorAll(".sidebar .row.session")].find((r) => r.innerText.includes(${JSON.stringify(title)}))?.click()`);
  await page.waitFor(chip, 10_000);
  await sleep(500);
  const all = await rows();
  console.log("all:", all);
  await page.shot(`${out}/web-all.png`);

  await page.eval(`${chip}.click()`);
  await sleep(600);
  const filtered = await rows();
  ok(`a click asks for the label (${await search()})`, (await search()) === `label:${label}`);
  ok(`the list is only those sessions: ${filtered.join(", ")}`, filtered.length > 0 && filtered.length < all.length);
  ok("the chip looks chosen", await page.eval(`${chip}.closest(".chip").classList.contains("chosen")`));
  ok("the chat stays open", await page.eval(`!!(${chip})`));
  await page.shot(`${out}/web-filtered.png`);

  await page.eval(`${chip}.click()`);
  await sleep(600);
  ok(`a second click clears it (${JSON.stringify(await search())})`, (await search()) === "");
  ok("every session again", (await rows()).length === all.length);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 400)}`);
  throw e;
} finally {
  await chrome.close();
}
