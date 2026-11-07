// The #3790 walk: Move to Machine… from a session's ··· menu, on a scratch control plane with a
// second host whose project folder is <folder there>. The sheet, a refusal (a folder that is not an
// absolute path), then the move with the folder left empty, into the project's folder there, after
// which the page opens the session on that machine.
//
//   node Web/test/walk/movetomachine3790.mjs <WEB_URL> <browser code> <out dir> <chat's #/h/…/s/… address> <folder there>

import { launch } from "./cdp.mjs";

const [webURL, code, out, chat, folder] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

const chrome = await launch({ profile: "/tmp/run-3790-chrome" });
const shot = async (page, name) => { await pause(600); await page.shot(`${out}/${name}.png`); };
const button = (words) => `[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === ${JSON.stringify(words)})`;
try {
  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".person-button")`, 30_000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".person-button")`, 30_000);
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  for (let i = 0; i < 30 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await pause(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits");
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
    await page.eval(`${button("OK")}?.click()`);
  }

  // The session's chat, by its address (#/h/‹host›/p/‹folder›/s/‹id›).
  await page.eval(`location.hash = ${JSON.stringify(chat)}`);
  await page.waitFor(`document.querySelector(".session-menu button[aria-label=More]") && !document.querySelector(".session-menu button[aria-label=More]").disabled`, 20_000);
  await page.eval(`document.querySelector(".session-menu button[aria-label=More]").click()`);
  await page.waitFor(`${button("Move to Machine…")}`);
  check(true, "the session's ··· menu has Move to Machine…");
  await shot(page, "web-menu");
  await page.eval(`${button("Move to Machine…")}.click()`);
  await page.waitFor(`document.querySelector("dialog.sheet .move-to-machine")`);
  check(await page.eval(`document.querySelector(".move-to-machine select")?.selectedOptions[0]?.textContent === "Workstation"`), "Workstation is chosen");
  await shot(page, "web-sheet");

  const typeFolder = (words) => page.eval(`(() => { const f = document.querySelector(".move-to-machine input[type=text]");
    f.value = ${JSON.stringify(words)}; f.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await typeFolder("login-page");
  await page.eval(`document.querySelector(".move-to-machine button[type=submit]").click()`);
  await page.waitFor(`document.querySelector(".move-to-machine .failure")`, 60_000);
  const refusal = await page.text(".move-to-machine .failure");
  check(refusal.includes("the folder on Workstation is an absolute path"), `refused in the person's words: ${refusal}`);
  await shot(page, "web-refused");

  await typeFolder("");
  await page.eval(`document.querySelector(".move-to-machine button[type=submit]").click()`);
  await page.waitFor(`!document.querySelector("dialog.sheet .move-to-machine")`, 120_000);
  await pause(3000);
  check(await page.eval(`decodeURIComponent(location.hash).includes(${JSON.stringify(folder)})`), `the page opened it there: ${await page.eval("location.hash")}`);
  await shot(page, "web-moved");
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
