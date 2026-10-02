// The #95 walk: queued prompts drawn as the person's own bubble, dashed and dimmed, with Send
// now and × underneath. Needs a scratch root with an agent mid-turn and prompts queued on it.
//
//   node Web/test/walk/queued.mjs <WEB_URL> <browser code> <out dir> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, width = "1440"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/095-queued-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".projects .row")`);
  await page.eval(`[...document.querySelectorAll(".projects .row")].find((e) => e.textContent.includes("work"))?.click()`);
  await page.waitFor(`document.querySelector(".sessions .session")`, 20_000);
  await page.eval(`document.querySelector(".sessions .session").click()`);
  await page.waitFor(`document.querySelectorAll(".queued").length >= 2`, 30_000);
  await new Promise((done) => setTimeout(done, 500));
  // Where the queued bubbles sit beside the sent one: the same right edge, and no wider than their words.
  const boxes = await page.eval(`JSON.stringify([...document.querySelectorAll(".bubble, .queued-bubble")].map((e) => {
    const r = e.getBoundingClientRect(), t = e.closest(".transcript").getBoundingClientRect();
    return { kind: e.className, right: Math.round(t.right - r.right), width: Math.round(r.width), label: e.getAttribute("aria-label")?.slice(0, 40) ?? null };
  }))`);
  console.log(`bubbles: ${boxes}`);
  console.log(`actions: ${await page.eval(`JSON.stringify([...document.querySelectorAll(".queued-actions")].map((e) => e.textContent.trim()))`)}`);
  console.log(`title gone: ${!(await page.text(".transcript")).includes("Waiting its turn")}`);
  await page.shot(`${out}/095-web-queued-${width}.png`);
} finally {
  await chrome.close();
}
