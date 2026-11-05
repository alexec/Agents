// The #3437 walk: the Changed files card at the end of a seeded turn, and Undo These Changes.
//
//   node Web/test/walk/undo3437.mjs <WEB_URL> <browser code> <session title> <out dir> card
//   node Web/test/walk/undo3437.mjs <WEB_URL> <browser code> <session title> <out dir> undo
//
// card shoots the card; undo presses Undo These Changes, answers the question (window.confirm, which no
// screenshot holds) with OK, prints what it asked, and shoots the card undone.

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, title, out, phase] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-undo3437-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(3000);
  for (const name of ["work", "Sessions"]) {
    await page.eval(`document.querySelector('[aria-label="Unfold ${name}"]')?.click()`);
    await sleep(1200);
  }
  await page.eval(`[...document.querySelectorAll("a,button,[role=button],[role=treeitem],[role=option],li")].reverse().find((e) => e.textContent.includes(${JSON.stringify(title)}))?.click()`);
  await page.waitFor(`document.querySelector(".turn-changes")`, 20_000);
  await sleep(1500);
  console.log("card:", await page.eval(`document.querySelector(".turn-changes").innerText.replace(/\\n+/g, " / ")`));
  if (phase === "card") {
    await page.shot(`${out}/web-changed.png`);
  } else {
    await page.eval(`window.asked = []; window.confirm = (m) => { window.asked.push(m); return true; }`);
    await page.press("Undo These Changes");
    await page.waitFor(`document.querySelector(".turn-changes").innerText.includes("Undone")`, 20_000);
    await sleep(800);
    console.log("asked:", await page.eval(`JSON.stringify(window.asked)`));
    await page.shot(`${out}/web-undone.png`);
  }
} finally {
  await chrome.close();
}
