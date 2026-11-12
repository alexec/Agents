// The #4789 walk: the web chat transcript is windowed. Needs a scratch root (run-app) with a long
// chat titled "seeded live 0" (scripts/seed-markdown-chat.py ROOT AGENT 400), whose machine the browser has approved. It pages the chat
// back to the cap, then says how many turns are laid out, how long a frame takes while scrolling
// through it, and whether the line read holds while earlier pages land, with the windowing and,
// for comparison, with it turned off by a style on the page.
//
//   node Web/test/walk/window4789.mjs <WEB_URL> <browser code> <ROOT> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, out] = process.argv.slice(2);
// PROFILE: a browser already paired, and the first to pair holds the lock, so it is never asked to approve.
const chrome = await launch({ profile: process.env.PROFILE ?? `${root}/chrome-4789-${process.pid}` });
const results = [];
const note = (item, pass, detail) => { results.push({ item, pass, detail }); console.log(`${pass ? "PASS" : "FAIL"} ${item}: ${detail}`); };
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  const T = `document.querySelector(".transcript")`;
  const geo = async () => JSON.parse(await page.eval(`(() => { const e = ${T}; return JSON.stringify({ top: e.scrollTop, h: e.scrollHeight, fromBottom: e.scrollHeight - e.scrollTop - e.clientHeight, jump: !!document.querySelector("button.jump"), turns: e.querySelectorAll("article.turn").length }); })()`));
  const wheel = async (deltaY) => {
    const r = JSON.parse(await page.eval(`JSON.stringify(${T}.getBoundingClientRect())`));
    await page.raw("Input.dispatchMouseEvent", { type: "mouseWheel", x: r.x + r.width / 2, y: r.y + r.height / 2, deltaX: 0, deltaY });
  };
  // Turns whose contents the browser skips: not laid out or painted.
  const laidOut = async () => JSON.parse(await page.eval(`(() => { const turns = [...${T}.querySelectorAll("article.turn")];
    const drawn = turns.filter((t) => t.querySelector("p, pre, li")?.checkVisibility({ contentVisibilityAuto: true }) ?? true).length;
    return JSON.stringify({ turns: turns.length, drawn }); })()`));
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) { await page.focus("textarea"); await page.type(code); await page.press("Connect"); }
  await page.waitFor(`[...document.querySelectorAll("a, button")].some((e) => e.textContent.trim() === "Agents")`, 20_000);
  await page.eval(`[...document.querySelectorAll("a, button")].find((e) => e.textContent.trim() === "Agents").click()`);
  await sleep(3000);
  // Unfold the folder when its sessions are not shown.
  if (!(await page.eval(`document.body.innerText.includes("seeded live 0")`))) {
    await page.eval(`(() => { const row = [...document.querySelectorAll(".row.folder")].find((e) => e.textContent.includes("work")); (row?.querySelector(".disclosure") ?? row?.querySelector(".pick"))?.click(); })()`);
  }
  await page.waitFor(`[...document.querySelectorAll("a, button, li, [role=row]")].some((e) => e.textContent.includes("seeded live 0"))`, 20_000);
  await page.eval(`[...document.querySelectorAll("a, button, li, [role=row]")].filter((e) => e.textContent.includes("seeded live 0")).pop().click()`);
  await page.waitFor(`${T} && ${T}.scrollHeight > ${T}.clientHeight + 100`, 20_000);
  await sleep(2000);
  let g = await geo();
  note("1 open at the end", g.fromBottom <= 1, `fromBottom ${g.fromBottom}, ${g.turns} turns`);
  await page.shot(`${out}/web-open.png`);

  // 2. Up to the top, page by page: the row read must not move as each page lands above it.
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
  for (let i = 0; i < 400; i++) {
    await wheel(-300); await sleep(450);
    if ((await geo()).top === 0 && !(await page.eval(`!!document.querySelector(".transcript .more")`))) break;
  }
  await sleep(1000);
  const moves = await page.eval(`window.__moves`);
  g = await geo();
  const bad = moves.filter((d) => d > 2);
  note("2 the row read holds as pages and turns land above", bad.length === 0, `${moves.length} changes of height, ${bad.length} moved the row: ${JSON.stringify(bad)}; ${g.turns} turns held`);
  await page.shot(`${out}/web-top.png`);

  // 3. Only the turns near the view are laid out.
  let l = await laidOut();
  note("3 only turns near the view are drawn", l.drawn > 0 && l.drawn < l.turns / 4, `${l.drawn} of ${l.turns} turns laid out at the top`);

  // 4. What a layout of the whole chat costs (a resize, a font change), and a frame while scrolling
  // through its middle, windowed and with every turn drawn. Earlier pages are all in by now.
  const cost = async () => JSON.parse(await page.eval(`(() => {
    const e = ${T}; const layouts = [];
    for (let i = 0; i < 6; i++) { const at = performance.now(); e.style.width = (i % 2 ? 700 : 720) + "px"; void e.scrollHeight; layouts.push(performance.now() - at); }
    e.style.width = ""; void e.scrollHeight; layouts.sort((a, b) => a - b);
    return JSON.stringify({ layout: layouts[3].toFixed(1) });
  })()`));
  const frames = async () => JSON.parse(await page.eval(`new Promise((done) => {
    const e = ${T}; e.scrollTop = 2000; const times = []; let last = performance.now();
    (function step() {
      const now = performance.now(); times.push(now - last); last = now;
      if (times.length > 240 || e.scrollTop + e.clientHeight >= e.scrollHeight - 2000) { times.sort((a, b) => a - b);
        done(JSON.stringify({ frames: times.length, p50: times[times.length >> 1].toFixed(1), p95: times[Math.floor(times.length * 0.95)].toFixed(1), worst: times[times.length - 1].toFixed(1) })); return; }
      e.scrollTop += 400; requestAnimationFrame(step);
    })();
  })`));
  const windowed = { ...(await cost()), ...(await frames()) };
  await page.eval(`(() => { const s = document.createElement("style"); s.id = "off4789"; s.textContent = ".transcript > .turn { content-visibility: visible !important; }"; document.head.append(s); })()`);
  await sleep(1500);
  const whole = { ...(await cost()), ...(await frames()) };
  await page.eval(`document.getElementById("off4789").remove()`);
  // Reported, not judged by the layout: on a fast Mac 160 turns lay out in about a millisecond either way.
  note("4 scrolling is no slower windowed", Number(windowed.p95) <= Number(whole.p95) + 2, `windowed ${JSON.stringify(windowed)}; every turn drawn ${JSON.stringify(whole)}`);

  // 5. Go to the end, and stay there.
  await sleep(1000);
  await page.eval(`document.querySelector("button.jump")?.click()`); await sleep(1500);
  g = await geo(); await sleep(1500); const g2 = await geo();
  note("5 go to the end", g.fromBottom <= 1 && g2.fromBottom <= 1 && !g2.jump, `fromBottom ${g.fromBottom} then ${g2.fromBottom}, jump ${g2.jump}`);
  l = await laidOut();
  note("5b only turns near the end are drawn", l.drawn > 0 && l.drawn < l.turns / 4, `${l.drawn} of ${l.turns} turns laid out at the end`);
  await page.shot(`${out}/web-end.png`);
} finally {
  await chrome.close();
}
process.exit(results.every((r) => r.pass) ? 0 : 1);
