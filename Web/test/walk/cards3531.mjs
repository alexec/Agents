// The #3531 walk: Settings ▸ Secrets on the web page, Add a Card…: the rule, the confirm box, the parts, and
// the row it adds, marked Card. The page seals the card's one value; no file of the control plane holds it.
//
//   node Web/test/walk/cards3531.mjs <WEB_URL> <browser code> <control home> <out dir>

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, pageCode, controlHome, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

function holds(dir, text) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory() ? holds(path, text) : readFileSync(path, "latin1").includes(text)) return true;
  }
  return false;
}

const chrome = await launch({ profile: `/tmp/run-card3531-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.innerText.includes("Settings")`, 30_000);
  await sleep(1500);
  await page.eval(`location.hash = "#/settings"`);
  await sleep(1000);
  await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add a Card…")`, 15_000);
  await page.eval(`document.getElementById("settings-secrets").scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-secrets.png`);
  await page.press("Add a Card…");
  await page.waitFor(`document.querySelector("input[aria-label='Card number']")`);
  await page.shot(`${out}/web-card-empty.png`);
  const fill = async (label, text) => { await page.focus(`input[aria-label='${label}']`); await page.type(text); };
  await fill("Name", "SHOP_CARD");
  await fill("Card number", "4242 4242 4242 4242");
  await fill("Expiry (MM/YY)", "09/31");
  await fill("CVC", "737");
  await fill("Name on card", "Sam Lee");
  await fill("Billing ZIP", "94110");
  check(await page.eval(`document.querySelector("form.sheet-body button[type=submit]").disabled`), "Add waits for the confirm box");
  await page.eval(`document.querySelector("form.sheet-body input[type=checkbox]").click()`);
  await sleep(200);
  check(!(await page.eval(`document.querySelector("form.sheet-body button[type=submit]").disabled`)), "Add once the box is ticked");
  await page.shot(`${out}/web-card-filled.png`);
  await page.eval(`document.querySelector("form.sheet-body").requestSubmit()`);
  await page.waitFor(`document.querySelector("code")?.innerText === "SHOP_CARD"`, 20_000);
  await sleep(500);
  await page.eval(`document.getElementById("settings-secrets").scrollIntoView()`);
  await sleep(300);
  await page.shot(`${out}/web-card-added.png`);
  check(await page.eval(`document.querySelector(".user-secret").innerText.includes("Card")`), "the row says Card");
  check(!holds(controlHome, "4242424242424242") && !holds(controlHome, "737\""), "no file of the control plane holds the card");
  check(holds(controlHome, "\"kind\": \"card\""), "the control plane keeps its kind");
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
