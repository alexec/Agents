// The layout walk (071 quickstart §3, T039): the three columns at every width of the look gate,
// on a scratch root with real projects and sessions, screenshotted beside frames A–F.
//
//   node Web/test/walk/layout.mjs <WEB_URL> <CONTROL_URL> <operator code> <session title> <out dir>
//
// Ends with frame F's two states: the control plane stopped (the caller stops it when the
// script prints "stop the control plane now"), and the browser forgotten.

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";
import { Operator } from "./operator.mjs";

const [webURL, controlURL, operatorCode, title, out] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };

const op = await Operator.pair(controlURL, operatorCode);
const chrome = await launch({ profile: `/tmp/071-layout-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type((await op.call("clients/startPairing", { grant: "device", kind: "browser" })).text);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

const clickRow = (text) => page.eval(`(() => {
  const row = [...document.querySelectorAll(".row")].find((r) => r.querySelector(".title")?.textContent === ${JSON.stringify(text)}
    && r.offsetParent !== null);
  row?.click();
  return !!row;
})()`);

/** Overlaps or cut-off text in what's visible: elements wider than their column, or the prompt off-screen. */
const problems = () => page.eval(`(() => {
  const found = [];
  const prompt = document.querySelector(".chat .prompt");
  if (prompt && prompt.offsetParent !== null) {
    const box = prompt.getBoundingClientRect();
    if (box.bottom > innerHeight + 1 || box.top < 0) found.push("the prompt is off-screen");
  }
  for (const column of document.querySelectorAll(".projects, .sessions, .chat, .files")) {
    if (column.offsetParent === null) continue;
    if (column.scrollWidth > column.clientWidth + 1) found.push(column.className + " scrolls sideways");
  }
  if (document.documentElement.scrollWidth > innerWidth + 1) found.push("the page scrolls sideways");
  // Every visible column starts at the top: none has wrapped onto a row of its own.
  const top = document.querySelector(".columns")?.getBoundingClientRect().top ?? 0;
  for (const column of document.querySelectorAll(".projects, .sessions, .chat, .files")) {
    if (column.offsetParent === null) continue;
    if (Math.abs(column.getBoundingClientRect().top - top) > 1) found.push(column.className + " has wrapped below the others");
  }
  return found;
})()`);

const visible = () => page.eval(`["projects","sessions","chat","files"].filter((c) => {
  const el = document.querySelector("." + c); return el && el.offsetParent !== null; })`);

async function at(width, height, name, frame) {
  await page.viewport(width, height);
  await sleep(250);
  await page.shot(`${out}/layout-${name}.png`);
  say(`${name} (${width}×${height}, against frame ${frame}): columns ${JSON.stringify(await visible())}; problems ${JSON.stringify(await problems())}`);
}

if (!(await clickRow("web-remote"))) throw new Error("no web-remote project");
await page.waitFor(`document.querySelector(".sessions .row")`);
if (!(await clickRow(title))) throw new Error(`no session called ${title}`);
await page.waitFor(`document.querySelectorAll(".transcript p").length > 10`);
say(`opened: ${await page.eval(`document.querySelectorAll(".sessions .row").length`)} sessions in web-remote, ${await page.eval(`document.querySelectorAll(".transcript p").length`)} lines in the chat`);

await at(1440, 900, "1440", "A");
await page.press("Files");
await page.waitFor(`document.querySelector(".files")`);
await at(1600, 900, "1600-files", "B");
await at(1300, 900, "1300-files-over-chat", "B, below 1440");
await page.press("Close Files");
await at(1000, 800, "1000", "C");
await page.eval(`document.querySelector(".project-menu").click()`);
await sleep(150);
await at(1000, 800, "1000-menu", "C, menu open");
await page.eval(`document.querySelector(".project-menu").click()`);

await at(390, 844, "390-chat", "D3");
await page.eval(`history.back()`);
await sleep(250);
await at(390, 844, "390-sessions", "D2 (after the browser's Back)");
await page.eval(`history.back()`);
await sleep(250);
await at(390, 844, "390-projects", "D1 (after Back again)");
await clickRow("web-remote");
await sleep(200);
await page.eval(`document.querySelector(".sessions .back").click()`);
await sleep(200);
say(`390 back control from sessions: columns ${JSON.stringify(await visible())}`);

// Frame F, left: the control plane stops; the page greys out and keeps what it showed.
await page.viewport(1440, 900);
await clickRow("web-remote");
await sleep(200);
await clickRow(title);
await page.waitFor(`document.querySelectorAll(".transcript p").length > 10`);
console.log("stop the control plane now");
await page.waitFor(`document.querySelector(".banner")`, 30_000);
await sleep(300);
await page.shot(`${out}/layout-f-down.png`);
say(`F, down: banner ${JSON.stringify(await page.text(".banner"))}; chat lines still shown ${await page.eval(`document.querySelectorAll(".transcript p").length`)}`);
writeFileSync(`${out}/layout-notes.txt`, notes.join("\n") + "\n");
console.log("start the control plane again");
await page.waitFor(`!document.querySelector(".banner") && document.querySelectorAll(".transcript p").length > 10`, 60_000);
say("F, back: reconnected by itself and caught up, with no reload");

// Frame F, right: forgotten in Settings.
const op2 = await Operator.pair(controlURL, process.env.OPERATOR_CODE_2);
// The browser this walk paired: the newest one, as a scratch root may keep older walks'.
const browser = (await op2.call("clients/list")).filter((c) => c.kind === "browser").sort((a, b) => b.paired - a.paired)[0];
await op2.call("clients/forget", { client: browser.id });
await page.waitFor(`document.body.innerText.includes("This browser was forgotten")`, 3000);
await page.shot(`${out}/layout-f-forgotten.png`);
say("F, forgotten: the pairing screen with the line saying why");
say(`checks: errors ${JSON.stringify(page.errors)}; requests off the page's origin ${JSON.stringify(page.requests.filter((r) => !r.startsWith(webURL)))}`);
writeFileSync(`${out}/layout-notes.txt`, notes.join("\n") + "\n");
await chrome.close();
op.stop();
op2.stop();
