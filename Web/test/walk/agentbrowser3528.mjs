// The Agent Browser tab walk (#3528): on a run-app root with one session, open its Files column's
// Agent Browser tab, see the machine's browser's page, open a test page from the bar, click into
// its field and type. Screenshots into <out dir>.
//
//   node Web/test/walk/agentbrowser3528.mjs <WEB_URL> <browser code> <out dir> <folder> <session title>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, folder, title] = process.argv.slice(2);
const chrome = await launch({ profile: process.env.PROFILE ?? `/tmp/3528-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1600, height: 900 });
const shot = async (name) => { await sleep(600); await page.shot(`${out}/${name}.png`); console.log(`shot ${name}.png`); };
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };

try {
  // A profile paired and approved already (PROFILE) goes straight in.
  await page.waitFor(`document.querySelector("textarea") || document.body.innerText.includes("Overview")`, 30_000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  // A new browser joins the machine lock (#3490): the window approves it, by hand, meanwhile.
  await sleep(3000);
  console.log("approve this browser in the window");
  await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  // The folder, unfolded, then the session in it: found by their words.
  const clickText = (text) => page.eval(`(() => {
    const el = [...document.querySelectorAll("button, a, [role=treeitem], [role=button], .row, li, div")]
      .filter((e) => e.offsetParent !== null && e.textContent.includes(${JSON.stringify(text)}))
      .sort((a, b) => a.textContent.length - b.textContent.length)[0];
    el?.click();
    return !!el;
  })()`);
  await page.waitFor(`document.body.innerText.includes(${JSON.stringify(folder)})`, 30_000);
  await clickText(folder);
  await page.waitFor(`document.body.innerText.includes(${JSON.stringify(title)})`, 30_000);
  await page.eval(`(() => { const r = [...document.querySelectorAll(".row.session")].find((r) => r.textContent.includes(${JSON.stringify(title)})); (r?.querySelector(".pick") ?? r)?.click(); })()`);
  await page.waitFor(`document.querySelector(".chat .transcript")`, 30_000);
  await page.press("Files");
  await page.waitFor(`document.querySelector("aside.files [role=tab]")`, 30_000);
  await page.press("Agent Browser");
  await page.waitFor(`document.querySelector(".agent-browser-frame") || document.querySelector(".agent-browser-note")`, 30_000);
  if (await page.eval(`!!document.querySelector(".agent-browser-note")`)) await shot("web-stopped");

  const go = async (address) => {
    await page.focus(".agent-browser-bar input");
    await page.eval(`(() => { const i = document.querySelector(".agent-browser-bar input"); i.value = ""; i.dispatchEvent(new Event("input", { bubbles: true })); })()`);
    await page.type(address);
    await page.raw("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" });
    await page.raw("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
  };
  await go("example.com");
  await page.waitFor(`document.querySelector(".agent-browser-bar input").value.includes("example.com") && !!document.querySelector(".agent-browser-frame")`, 120_000);
  await sleep(1500);
  await shot("web-page");

  await go(`data:text/html,<title>Sign in</title><body style="font:20px system-ui;margin:24px"><h2>Sign in</h2><input placeholder="Name" style="font:20px system-ui;width:90%;height:500px">`);
  await page.waitFor(`document.querySelector(".agent-browser-bar input").value.startsWith("data:")`, 30_000);
  await sleep(1500);
  const box = await page.eval(`(() => { const r = document.querySelector(".agent-browser-page").getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  for (const type of ["mousePressed", "mouseReleased"]) {
    await page.raw("Input.dispatchMouseEvent", { type, x: box.x, y: box.y, button: "left", clickCount: 1 });
  }
  await sleep(500);
  ok("the page area has the keys", await page.eval(`document.activeElement === document.querySelector(".agent-browser-page")`));
  for (const ch of "hello") {
    const upper = ch.toUpperCase();
    await page.raw("Input.dispatchKeyEvent", { type: "keyDown", key: ch, code: `Key${upper}`, windowsVirtualKeyCode: upper.charCodeAt(0), text: ch });
    await page.raw("Input.dispatchKeyEvent", { type: "keyUp", key: ch, code: `Key${upper}`, windowsVirtualKeyCode: upper.charCodeAt(0) });
    await sleep(150);
  }
  await sleep(2000);
  await shot("web-typing");
} catch (error) {
  await page.shot(`${out}/failed.png`);
  console.log(await page.text());
  throw error;
} finally {
  await chrome.close();
}
