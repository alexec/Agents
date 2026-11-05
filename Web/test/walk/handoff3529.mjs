// The hand-off card walk (#3529): on a run-app root with one session waiting on a
// hand_to_person card, see the card, press Open the page (the Agent Browser tab opens beside
// the chat), then Can't do it with a line. Screenshots into <out dir>.
//
//   node Web/test/walk/handoff3529.mjs <WEB_URL> <browser code> <out dir> <folder> <session title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, folder, title] = process.argv.slice(2);
const chrome = await launch({ profile: process.env.PROFILE ?? `/tmp/3529-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1600, height: 900 });
const shot = async (name) => { await sleep(600); await page.shot(`${out}/${name}.png`); console.log(`shot ${name}.png`); };
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };

try {
  await page.waitFor(`document.querySelector("textarea") || document.body.innerText.includes("Overview")`, 30_000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  await sleep(3000);
  console.log("approve this browser in the window");
  await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  // The folder, once it is listed and has settled, unfolded; then the session in it.
  await page.waitFor(`document.body.innerText.includes(${JSON.stringify(folder)})`, 30_000);
  await sleep(3000);
  await page.eval(`document.querySelector('[aria-label="Unfold ' + ${JSON.stringify(folder)} + '"]')?.click()`);
  await page.waitFor(`document.body.innerText.includes(${JSON.stringify(title)})`, 30_000);
  await page.eval(`(() => { const r = [...document.querySelectorAll(".row.session")].find((r) => r.textContent.includes(${JSON.stringify(title)})); (r?.querySelector(".pick") ?? r)?.click(); })()`);
  await page.waitFor(`document.body.innerText.includes("Open the page")`, 30_000);
  await shot("web-card");

  await page.press("Open the page");
  await page.waitFor(`document.querySelector(".agent-browser-frame") || document.querySelector(".agent-browser-note")`, 30_000);
  ok("Open the page opens the Agent Browser tab", await page.eval(`!!document.querySelector("aside.files")`));
  await shot("web-open");

  await page.press("Can't do it");
  await page.waitFor(`!!document.querySelector('input[placeholder="What stopped you (optional)"]')`, 10_000);
  await page.focus('input[placeholder="What stopped you (optional)"]');
  await page.type("It wants a phone number.");
  await shot("web-cannot");
} catch (error) {
  await page.shot(`${out}/failed.png`);
  console.log(await page.text());
  throw error;
} finally {
  await chrome.close();
}
