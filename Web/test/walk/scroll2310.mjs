// The #2310 walk: the chat's place on the web page, measured per frame. Needs a scratch root
// (run-app) seeded with a long chat in folder "proj00" whose title holds "seeded live 0"
// (scripts/seed-markdown-chat.py, 97 turns).
//
//   node Web/test/walk/scroll2310.mjs <WEB_URL> <browser code> <ROOT> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out] = process.argv.slice(2);
const chrome = await launch({ profile: `${root}/chrome-2310-${process.pid}` });
const results = [];
const note = (item, pass, detail) => { results.push({ item, pass, detail }); console.log(`${pass ? "PASS" : "FAIL"} ${item}: ${detail}`); };
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  const T = `document.querySelector(".transcript")`;
  const geo = async () => JSON.parse(await page.eval(`(() => { const e = ${T}; return JSON.stringify({ top: e.scrollTop, h: e.scrollHeight, fromBottom: e.scrollHeight - e.scrollTop - e.clientHeight, jump: !!document.querySelector("button.jump") }); })()`));
  const wheel = async (deltaY) => {
    const r = JSON.parse(await page.eval(`JSON.stringify(${T}.getBoundingClientRect())`));
    await page.raw("Input.dispatchMouseEvent", { type: "mouseWheel", x: r.x + r.width / 2, y: r.y + r.height / 2, deltaX: 0, deltaY });
  };
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea"); await page.type(code); await page.press("Connect");
  await page.waitFor(`document.querySelector(".row.folder")`, 20_000);
  await page.eval(`document.querySelector(".row.folder .disclosure")?.click()`);
  await page.waitFor(`[...document.querySelectorAll(".row.session")].some((e) => e.textContent.includes("seeded live 0"))`, 20_000);
  await page.eval(`[...document.querySelectorAll(".row.session .pick, .row.session")].find((e) => e.textContent.includes("seeded live 0"))?.click()`);
  await page.waitFor(`${T} && ${T}.scrollHeight > ${T}.clientHeight + 100`, 20_000);
  await sleep(2000);
  let g = await geo();
  note("1 open at the end", g.fromBottom <= 1, `fromBottom ${g.fromBottom}`);

  // 2. One small wheel tick up is reading back, at once.
  await wheel(-40); await sleep(400);
  g = await geo();
  note("2 a tick up reads back", g.jump && g.fromBottom > 1, `fromBottom ${g.fromBottom}, jump ${g.jump}`);

  // 3. Every change of height while reading (a page above, steps that come, a picture): the
  // first row starting on the pane is watched every frame and must not move.
  await page.eval(`(() => {
    const e = ${T};
    window.__moves = []; let anchor = null, at = 0, h = e.scrollHeight, watching = 0, worst = 0;
    const pick = () => { const t = e.getBoundingClientRect().top; anchor = [...e.querySelectorAll("article.turn")].find((r) => r.getBoundingClientRect().top > t + 20) ?? null; at = anchor ? anchor.getBoundingClientRect().top : 0; };
    e.addEventListener("scroll", () => { if (!watching && e.scrollHeight === h) pick(); });
    (function tick() {
      if (e.scrollHeight !== h) { if (anchor && !watching) { watching = 12; worst = 0; } h = e.scrollHeight; }
      if (watching && anchor) {
        const moved = anchor.isConnected ? Math.abs(anchor.getBoundingClientRect().top - at) : 9999;
        worst = Math.max(worst, moved);
        if (--watching === 0) { window.__moves.push(Math.round(worst)); pick(); }
      }
      requestAnimationFrame(tick);
    })();
  })()`);
  // A beat longer than the twelve frames watched, so the wheel is never counted as the row moving.
  for (let i = 0; i < 250; i++) {
    await wheel(-300); await sleep(450);
    if ((await geo()).top === 0 && !(await page.eval(`!!document.querySelector(".transcript .more")`))) break;
  }
  await sleep(1000);
  await page.shot(`${out}/web-2310-top.png`);
  const moves = await page.eval(`window.__moves`);
  g = await geo();
  note("3 growth above holds the row", moves.length > 0 && moves.every((d) => d <= 2), `${moves.length} changes of height; the row read moved by ${JSON.stringify(moves)}px; at scrollTop ${g.top} of ${g.h}`);

  // 4. Go to the end, and stay there.
  await page.eval(`document.querySelector("button.jump")?.click()`); await sleep(1500);
  g = await geo(); await sleep(1500); const g2 = await geo();
  note("4 go to the end", g.fromBottom <= 1 && g2.fromBottom <= 1 && !g2.jump, `fromBottom ${g.fromBottom} then ${g2.fromBottom}, jump ${g2.jump}`);
  await page.shot(`${out}/web-2310-end.png`);
} finally {
  await chrome.close();
}
process.exit(results.every((r) => r.pass) ? 0 : 1);
