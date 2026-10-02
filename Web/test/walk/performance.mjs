// SC-004 (T070): with 20 projects and 200 sessions on the host, how long from navigating to the
// page until the chosen project's sessions column is painted, in headless Chrome. The browser
// pairs once; each run after is a fresh navigation that connects with the stored key, loads
// everything, and draws, as opening the page does. Also the gzipped size of what it loads.
//
//   node Web/test/walk/performance.mjs <WEB_URL> <device code> <project name> <sessions expected> <out dir>

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { join } from "node:path";
import { launch } from "./cdp.mjs";

const [webURL, deviceCode, projectName, expected, out] = process.argv.slice(2);
const runs = 7;
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };

// When the column first holds every session, then the frame after: painted.
const probe = `(() => {
  const want = ${Number(expected)};
  const seen = () => document.querySelectorAll(".sessions .session").length >= want;
  const projects = () => document.querySelectorAll(".projects .row").length;
  const done = () => requestAnimationFrame(() => setTimeout(() => {
    window.__painted = { at: performance.now(), projects: projects(), sessions: document.querySelectorAll(".sessions .session").length };
  }, 0));
  new MutationObserver((_, observer) => { if (seen()) { observer.disconnect(); done(); } })
    .observe(document, { childList: true, subtree: true });
})();`;

const chrome = await launch({ profile: `/tmp/071-perf-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1440, height: 900 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(deviceCode);
await page.press("Connect");
await page.waitFor(`document.querySelectorAll(".projects .row").length >= 20`, 30_000);
await page.eval(`[...document.querySelectorAll(".projects .row")].find((r) => r.textContent.startsWith(${JSON.stringify(projectName)}))?.click()`);
await page.waitFor(`document.querySelectorAll(".sessions .session").length >= ${Number(expected)}`, 30_000);
const url = await page.eval("location.href");
say(`paired; the project is at ${url.slice(webURL.length - 1)}`);

await page.onNewDocument(probe);
const times = [];
for (let i = 0; i < runs; i++) {
  // Through a blank page: the same address with only its hash would not load a new document.
  await page.goto("about:blank");
  await page.goto(url);
  await page.waitFor("window.__painted", 30_000);
  const painted = await page.eval("window.__painted");
  const nav = await page.eval(`(() => { const n = performance.getEntriesByType("navigation")[0]; return { dom: n.domContentLoadedEventEnd, load: n.loadEventEnd }; })()`);
  times.push(painted.at);
  say(`run ${i + 1}: ${painted.projects} projects, ${painted.sessions} sessions painted at ${painted.at.toFixed(0)} ms (DOMContentLoaded ${nav.dom.toFixed(0)} ms)`);
}
const sorted = [...times].sort((a, b) => a - b);
say(`median ${sorted[Math.floor(runs / 2)].toFixed(0)} ms, slowest ${sorted[runs - 1].toFixed(0)} ms, fastest ${sorted[0].toFixed(0)} ms, over ${runs} runs`);
await page.shot(`${out}/performance-sessions.png`);

const dist = new URL("../../dist/", import.meta.url).pathname;
let total = 0, gzipped = 0;
const walk = (folder) => readdirSync(folder, { withFileTypes: true })
  .flatMap((e) => (e.isDirectory() ? walk(join(folder, e.name)).map((n) => `${e.name}/${n}`) : [e.name]));
for (const name of walk(dist).filter((n) => n !== "MANIFEST")) {
  const bytes = readFileSync(join(dist, name));
  const z = gzipSync(bytes, { level: 9 }).length;
  total += bytes.length; gzipped += z;
  say(`${name}: ${(bytes.length / 1024).toFixed(1)} KB, ${(z / 1024).toFixed(1)} KB gzipped`);
}
say(`all: ${(total / 1024).toFixed(1)} KB, ${(gzipped / 1024).toFixed(1)} KB gzipped`);
say(`page errors: ${JSON.stringify(page.errors)}`);
writeFileSync(`${out}/performance-notes.txt`, notes.join("\n") + "\n");
await chrome.close();
