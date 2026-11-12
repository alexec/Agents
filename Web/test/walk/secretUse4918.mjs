// A secret's use as a card in its session's chat (#4918), on a run-app root seeded with an open
// secretUse request asked by a live session: the card's words and buttons, then Deny on the card,
// which takes the card away. Screenshots into <out dir>. The scratch window approves the browser
// into the lock while this waits (walk.py … press "=Compare Digits", then the lock card's Approve).
//
//   node Web/test/walk/secretUse4918.mjs <WEB_URL> <browser code> <session address> <out dir>
//
// <session address> is the hash of the asking session: #/h/mac/p/<url-encoded folder URL>/s/<agent id>.

import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, address, out] = process.argv.slice(2);
const chrome = await launch({ profile: "/tmp/run-4918-chrome" });
const page = await chrome.page(webURL, { width: 1100, height: 760 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const shot = async (name) => { await scrub(); await page.shot(`${out}/${name}.png`); };
const cardText = () => page.eval(`[...document.querySelectorAll(".secret-use-card")].map((e) => e.innerText.replace(/\\s+/g, " ").trim())`);

try {
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  // A new browser asks to join the lock: wait for the ask, then for the window's approval.
  await page.waitFor(`document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000).catch(() => {});
  await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 180_000);
  await page.eval(`location.reload()`);
  await sleep(1500);
  await page.eval(`location.hash = ${JSON.stringify(address)}`);
  try {
    await page.waitFor(`!!document.querySelector(".secret-use-card")`, 30_000);
  } catch (error) {
    await shot("web-debug");
    console.log(await page.eval(`location.hash + " | " + document.body.innerText.slice(0, 600)`));
    throw error;
  }
  await sleep(800);
  const cards = await cardText();
  ok(`one card: ${cards.join(" | ")}`, cards.length === 1);
  ok("it names the secret and the place, with four answers",
    /Wants to use SHOP_PASSWORD/.test(cards[0]) && /Fill on shop\.example\.com/.test(cards[0])
    && /Deny.*Always Approve.*Approve for This Session.*Approve/.test(cards[0]));
  await shot("web-card");
  await page.eval(`[...document.querySelectorAll(".secret-use-card button")].find((b) => b.textContent === "Deny").click()`);
  await page.waitFor(`!document.querySelector(".secret-use-card")`, 15_000);
  ok("Deny takes the card away", (await cardText()).length === 0);
  await sleep(500);
  await shot("web-after-deny");
} finally {
  await chrome.close();
}
