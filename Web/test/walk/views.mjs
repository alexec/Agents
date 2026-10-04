// The #187 walk: a tool's ui:// view on the web page. Pairs, opens the session that called
// show_test_view, and shoots the view inline (light and dark), taller, full screen and back; presses
// Count inside the view (by position: the view is another origin, out of reach of eval), asks the
// agent through it and says Send, gives it context, and opens another chat so the view is torn
// down. What happened inside the view is in the daemon's log, which the view writes to.
//
//   node Web/test/walk/views.mjs <WEB_URL> <browser code> <out dir> <session title> [other session title]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, session, other] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/187-views-chrome-${process.pid}` });
const js = JSON.stringify;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  const scheme = (value) => page.raw("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value }] });
  const click = async (x, y) => {
    for (const type of ["mousePressed", "mouseReleased"]) {
      await page.raw("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
    }
  };
  const slot = async () => JSON.parse(await page.eval(`JSON.stringify(document.querySelector(".view-slot")?.getBoundingClientRect())`) ?? "null");
  // Positions inside the test view, from its own layout: 16 in, the rows 10 apart.
  const inView = async (dx, dy) => { const r = await slot(); await click(r.x + dx, r.y + dy); };

  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.project")`, 20_000);
  await sleep(800);
  const find = (text) => `[...document.querySelectorAll(".sidebar button, .sidebar summary")].find((b) => b.innerText.includes(${js(text)}))`;
  await page.eval(`document.querySelectorAll('.sidebar .disclosure[aria-expanded="false"]').forEach((b) => b.click())`);
  await sleep(800);
  await page.waitFor(`!!${find(session)}`, 20_000);
  await page.eval(`${find(session)}.click()`);
  await page.waitFor(`!!document.querySelector(".view-box iframe")`, 20_000);
  await sleep(3000);
  console.log("slot:", js(await slot()));
  console.log("proxy:", await page.eval(`document.querySelector(".view-box iframe")?.src`));
  console.log("sandbox:", await page.eval(`document.querySelector(".view-box iframe")?.getAttribute("sandbox")`));

  for (const value of ["light", "dark"]) {
    await scheme(value);
    await sleep(800);
    await page.shot(`${out}/web-inline-${value}.png`);
  }
  await scheme("light");
  await sleep(500);

  // Count: the third row's button.
  await inView(40, 103);
  await sleep(1500);
  await inView(40, 103);
  await sleep(1500);
  // Taller: the last row's first button.
  const before = (await slot()).height;
  await inView(40, 205);
  await sleep(1500);
  console.log("height:", before, "→", (await slot()).height);
  await page.shot(`${out}/web-taller.png`);

  // Full screen from the caption, and back.
  await page.eval(`[...document.querySelectorAll(".view-caption button")].find((b) => b.innerText.includes("Full screen")).click()`);
  await sleep(1500);
  await page.shot(`${out}/web-fullscreen.png`);
  await page.eval(`[...document.querySelectorAll(".view-box.full .view-bar button")][0].click()`);
  await sleep(1200);

  // Ask the agent: the person is asked first, under the view.
  const row = await slot();
  await page.eval(`document.querySelector(".view-slot").scrollIntoView({ block: "center" })`);
  await sleep(500);
  const buttons = await slot();
  // The last row: Taller, Fullscreen/Inline, Ask the agent, Give context, Open the spec.
  await click(buttons.x + 230, buttons.y + 205);
  await sleep(1500);
  console.log("asked:", await page.eval(`document.querySelector(".view-ask")?.innerText ?? "(no ask)"`));
  await page.shot(`${out}/web-ask.png`);
  await page.eval(`[...document.querySelectorAll(".view-ask button")].find((b) => b.innerText === "Send")?.click()`);
  await sleep(1000);
  await click(buttons.x + 330, buttons.y + 205);
  await sleep(1500);
  console.log("context:", await page.eval(`document.querySelector(".view-context")?.innerText ?? "(no context line)"`));
  console.log("row moved by", buttons.y - row.y);

  if (other) {
    await page.waitFor(`!!${find(other)}`, 20_000);
    await page.eval(`${find(other)}.click()`);
    await sleep(3000);
  }
  if (page.errors.length) console.log("errors:", page.errors.join("\n"));
} finally {
  await chrome.close();
}
