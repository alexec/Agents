// The #2957 slice 5 walk: the Stopped by a policy cards in a seeded chat (frame E), and a folder's layer opened
// from a card's Change, with a looser change from outside the app waiting (frame D).
//
//   node Web/test/walk/policy2957s5.mjs <WEB_URL> <page browser code> <session title> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, pageCode, title, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-p2957-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(3000);
  // Unfold the folder and its Sessions, then open the session.
  for (const name of ["work", "Sessions"]) {
    await page.eval(`document.querySelector('[aria-label="Unfold ${name}"]')?.click()`);
    await sleep(1200);
  }
  await page.eval(`[...document.querySelectorAll("a,button,[role=button],[role=treeitem],[role=option],li")].reverse().find((e) => e.textContent.includes(${JSON.stringify(title)}))?.click()`);
  await page.waitFor(`document.querySelector(".policy-stop")`, 20_000);
  await sleep(1500);
  await page.shot(`${out}/web-stopped.png`);
  console.log("cards:", await page.eval(`[...document.querySelectorAll(".policy-stop")].map((c) => c.innerText.replace(/\\n+/g, " / ")).join(" || ")`));
  await page.eval(`[...document.querySelectorAll(".policy-stop button")].at(-1).click()`);
  await page.waitFor(`document.querySelector(".policy-rule")`, 20_000);
  await sleep(2000);
  await page.eval(`document.getElementById("settings-scope-agents")?.scrollIntoView({ block: "start" })`);
  await sleep(500);
  await page.shot(`${out}/web-folder-policy.png`);
  console.log("hash:", await page.eval(`location.hash`));
} finally {
  await chrome.close();
}
