// The #378 walk: chat scrolling on the web page, each behaviour measured per frame rather than
// looked at. Needs a scratch root (run-app) whose host offers the demo runtime
// (`launch.sh --env AGENTS_TEST_RUNTIME=echo`), a project "work" with a long demo session whose
// first prompt starts "Turn 0" (a few hundred turns) and a short one whose first prompt starts
// "A short second". New turns are sent to the long one over the host's socket.
//
//   node Web/test/walk/scroll378.mjs <WEB_URL> <browser code> <ROOT> <long agent id> <out dir>

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, root, longID, out] = process.argv.slice(2);
const scripts = join(dirname(fileURLToPath(import.meta.url)), "../../../.agents/skills/run-app/scripts");
const sender = `import sys, time
sys.path.insert(0, sys.argv[1])
from rpc import Client
c = Client(sys.argv[2])
for i in range(int(sys.argv[4])):
    c.call("agents/prompt", {"agentID": sys.argv[3], "text": f"Live line {time.time():.0f}-{i}: " + "growing words " * 30, "attachments": [], "from": "person"})
    time.sleep(float(sys.argv[5]))`;
const send = (n, gap = 0.3) => execFileSync("python3", ["-c", sender, scripts, root, longID, String(n), String(gap)]);
const chrome = await launch({ profile: `${root}/chrome-378-${process.pid}` });
const results = [];
const note = (item, pass, detail) => { results.push({ item, pass, detail }); console.log(`${pass ? "PASS" : "FAIL"} ${item}: ${detail}`); };
try {
  const page = await chrome.page(webURL, { width: 1280, height: 800 });
  const T = `document.querySelector(".transcript")`;
  const geo = async () => JSON.parse(await page.eval(`(() => { const e = ${T}; return JSON.stringify({ top: e.scrollTop, h: e.scrollHeight, c: e.clientHeight, fromBottom: e.scrollHeight - e.scrollTop - e.clientHeight, jump: !!document.querySelector("button.jump"), news: !!document.querySelector("button.jump.news") }); })()`));
  const wheel = async (deltaY) => {
    const r = JSON.parse(await page.eval(`JSON.stringify(${T}.getBoundingClientRect())`));
    await page.raw("Input.dispatchMouseEvent", { type: "mouseWheel", x: r.x + r.width / 2, y: r.y + r.height / 2, deltaX: 0, deltaY });
  };
  const key = async (key, keyCode, modifiers = 0) => {
    for (const type of ["rawKeyDown", "keyUp"]) await page.raw("Input.dispatchKeyEvent", { type, key, code: key, modifiers, windowsVirtualKeyCode: keyCode });
  };
  // The row at the top of the pane and how far down it sits, to see whether what is read moved.
  const reading = async () => JSON.parse(await page.eval(`(() => { const e = ${T}; const t = e.getBoundingClientRect().top;
    const rows = [...e.querySelectorAll("p, .bubble")]; const row = rows.find((r) => r.getBoundingClientRect().bottom > t + 10);
    return JSON.stringify({ text: row?.textContent.slice(0, 50), y: row ? Math.round(row.getBoundingClientRect().top - t) : null }); })()`));

  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea"); await page.type(code); await page.press("Connect");
  await page.waitFor(`document.querySelector(".row.project")`, 20_000);
  await page.eval(`document.querySelector(".row.project .disclosure").click()`);
  await page.waitFor(`document.querySelectorAll(".row.session").length >= 2`, 20_000);
  const openSession = (needle) => page.eval(`[...document.querySelectorAll(".row.session .pick, .row.session")].find((e) => e.textContent.includes(${JSON.stringify(needle)}))?.click()`);

  // 1. Opening lands on the end with no flash of the top.
  await page.eval(`window.__samples = []; (function tick() { const e = document.querySelector(".transcript"); if (e && e.scrollHeight > e.clientHeight) window.__samples.push(e.scrollTop); if (window.__samples.length < 120) requestAnimationFrame(tick); })()`);
  await openSession("Turn 0");
  await page.waitFor(`${T} && ${T}.scrollHeight > ${T}.clientHeight + 100`, 20_000);
  await sleep(2000);
  const samples = await page.eval(`window.__samples`);
  let g = await geo();
  const tops = samples.filter((s) => s < 50).length;
  note("1 open", g.fromBottom <= 1 && tops === 0, `fromBottom ${g.fromBottom}, frames at the top ${tops} of ${samples.length}`);
  await page.shot(`${out}/web-1-open.png`);

  // 2. Following: new turns arrive while at the end.
  await page.eval(`window.__worst = 0; window.__watch = true; (function tick() { const e = document.querySelector(".transcript"); window.__worst = Math.max(window.__worst, e.scrollHeight - e.scrollTop - e.clientHeight); if (window.__watch) requestAnimationFrame(tick); })()`);
  send(6, 0.25); await sleep(1500);
  const worst = await page.eval(`window.__worst`); await page.eval(`window.__watch = false`);
  g = await geo();
  note("2 follow", g.fromBottom <= 1 && worst <= 2, `after 6 arrivals fromBottom ${g.fromBottom}, worst frame ${Math.round(worst)}px behind`);

  // 3. Reading back: one small wheel tick up stops following.
  await wheel(-40); await sleep(400);
  const before = await geo(); const at = await reading();
  send(3, 0.2); await sleep(1200);
  const after = await geo(); const at2 = await reading();
  note("3 read back (small tick)", Math.abs(after.top - before.top) <= 1 && at.text === at2.text && at.y === at2.y,
    `tick moved to ${before.fromBottom}px from the end; after 3 arrivals scrollTop ${before.top}→${after.top}, row "${at.text}" y ${at.y}→${at2.y}, jump ${after.jump}, news ${after.news}`);
  await wheel(-600); await sleep(400);
  const b2 = await geo(); send(3, 0.2); await sleep(1200); const a2 = await geo();
  note("3 read back (big)", Math.abs(a2.top - b2.top) <= 1 && a2.jump && a2.news, `scrollTop ${b2.top}→${a2.top}, jump ${a2.jump}, news ${a2.news}`);
  // Growth above the pane: a row above the fold grows by 300px.
  const r0 = await reading();
  await page.eval(`(() => { const e = ${T}; const t = e.getBoundingClientRect().top; const above = [...e.querySelectorAll(".bubble")].filter((r) => r.getBoundingClientRect().bottom < t - 50).pop(); if (above) above.style.paddingBottom = "300px"; })()`);
  await sleep(300); const r1 = await reading();
  note("3 growth above", r0.text === r1.text && Math.abs(r0.y - r1.y) <= 2, `row "${r0.text}" y ${r0.y}→${r1.y}`);

  // 4. Getting back: by hand, by Jump to end, by sending.
  for (let i = 0; i < 20; i++) { await wheel(400); await sleep(30); } await sleep(500);
  g = await geo(); send(2, 0.2); await sleep(900); let g2 = await geo();
  note("4 back by hand", g2.fromBottom <= 1 && !g2.jump, `at the end fromBottom ${g.fromBottom}; after arrivals ${g2.fromBottom}, jump ${g2.jump}`);
  await wheel(-800); await sleep(400); send(1); await sleep(600);
  await page.eval(`document.querySelector("button.jump")?.click()`); await sleep(900);
  send(2, 0.2); await sleep(900); g2 = await geo();
  note("4 jump to end", g2.fromBottom <= 1 && !g2.jump, `fromBottom ${g2.fromBottom}, jump ${g2.jump}`);
  await wheel(-800); await sleep(400);
  await page.focus(".foot textarea"); await page.type("Sent from the page while reading back"); await page.key("Enter"); await sleep(1500);
  g2 = await geo();
  note("4 send resumes", g2.fromBottom <= 1 && !g2.jump, `fromBottom ${g2.fromBottom}, jump ${g2.jump}`);

  // 5. Earlier history: the row being read, watched every frame as each page lands above it.
  await page.eval(`(() => {
    const e = document.querySelector(".transcript");
    window.__loads = []; let anchor = null, at = 0, h = e.scrollHeight, watching = 0, worst = 0;
    const pick = () => { const t = e.getBoundingClientRect().top; anchor = [...e.querySelectorAll("p, .bubble")].find((r) => r.getBoundingClientRect().top > t + 20) ?? null; at = anchor ? anchor.getBoundingClientRect().top : 0; };
    e.addEventListener("scroll", () => { if (!watching && e.scrollHeight === h) pick(); });
    (function tick() {
      if (e.scrollHeight !== h) { if (anchor && !watching) { watching = 12; worst = 0; } h = e.scrollHeight; }
      if (watching && anchor) {
        const moved = anchor.isConnected ? Math.abs(anchor.getBoundingClientRect().top - at) : 9999;
        worst = Math.max(worst, moved);
        if (--watching === 0) { window.__loads.push(Math.round(worst)); pick(); }
      }
      requestAnimationFrame(tick);
    })();
  })()`);
  for (let i = 0; i < 80; i++) {
    await wheel(-250); await sleep(250);
    if ((await geo()).top === 0 && !(await page.eval(`!!document.querySelector(".transcript .more")`))) break;
  }
  await sleep(1000);
  await page.shot(`${out}/web-5-top.png`);
  const loads = await page.eval(`window.__loads`);
  g = await geo();
  note("5 earlier", loads.length > 0 && loads.every((d) => d <= 4), `${loads.length} pages landed; the row being read moved by ${JSON.stringify(loads)}px; ended at scrollTop ${g.top} of ${g.h}`);

  await page.focus(".foot textarea"); await page.eval(`document.querySelector("button.jump")?.click()`); await sleep(1500);
  // 6. Keyboard, with the prompt not taking keys.
  await page.eval(`document.activeElement?.blur()`);
  let k0 = await geo(); await key("PageUp", 33); await sleep(500); let k1 = await geo();
  const pageUp = k0.top - k1.top;
  await key("PageDown", 34); await sleep(500); let k2 = await geo();
  await page.eval(`window.__min = Infinity; ${T}.addEventListener("scroll", (e) => { window.__min = Math.min(window.__min, e.currentTarget.scrollTop); })`);
  await key("Home", 36); await sleep(700); let k3 = await geo(); const homeMin = await page.eval(`window.__min`);
  await key("End", 35); await sleep(700); let k4 = await geo();
  await page.eval(`window.__min = Infinity`);
  await key("ArrowUp", 38, 4); await sleep(700); let k5 = await geo(); const upMin = await page.eval(`window.__min`);
  await key("ArrowDown", 40, 4); await sleep(700); let k6 = await geo();
  await key(" ", 32, 8); await sleep(500); let k7 = await geo();
  note("6 keyboard", pageUp > 100 && k2.top > k1.top && homeMin < 5 && k4.fromBottom <= 1 && upMin < 5 && k6.fromBottom <= 1 && k7.top < k6.top,
    `PageUp moved ${pageUp}, PageDown ${k2.top - k1.top}, Home reached ${homeMin} (then held at ${k3.top} as the page above landed), End →fromBottom ${k4.fromBottom}, ⌘↑ reached ${upMin}, ⌘↓ →fromBottom ${k6.fromBottom}, ⇧Space ${k7.top - k6.top}`);

  // 7. Coming back to a session.
  await key("End", 35); await sleep(1200);
  for (let i = 0; i < 6; i++) { await wheel(-500); await sleep(80); } await sleep(500);
  const was = await reading();
  await openSession("A short second"); await sleep(1500);
  await openSession("Turn 0"); await sleep(2500);
  const now = await reading(); g = await geo();
  note("7 come back (reading)", was.text === now.text, `was "${was.text}" y ${was.y}; now "${now.text}" y ${now.y}, fromBottom ${g.fromBottom}`);

  // 9. Performance: frame times while wheeling through the long session.
  await page.eval(`window.__frames = []; window.__go = true; let last = performance.now(); (function tick(now) { window.__frames.push(now - last); last = now; if (window.__go) requestAnimationFrame(tick); })(last)`);
  for (let i = 0; i < 60; i++) { await wheel(200); await sleep(16); }
  await page.eval(`window.__go = false`);
  const frames = (await page.eval(`window.__frames`)).slice(2);
  const sorted = [...frames].sort((a, b) => a - b); const p95 = sorted[Math.floor(sorted.length * 0.95)];
  const rowsN = await page.eval(`document.querySelectorAll(".transcript > *").length`);
  note("9 performance", p95 < 34, `${rowsN} children, ${frames.length} frames, p95 ${p95?.toFixed(1)}ms, worst ${sorted.at(-1)?.toFixed(1)}ms`);
} finally {
  await chrome.close();
  console.log(JSON.stringify(results));
}
