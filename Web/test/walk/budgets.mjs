// The web page's times at night (#4784), from its own `performance` marks (Web/src/model/marks.ts),
// in headless Chrome with a throwaway profile, against the `night.web` budgets in
// scripts/perf-budgets.json. scripts/perf-nightly.sh runs it on a seeded scratch root.
//
//   node Web/test/walk/budgets.mjs <ROOT> <WEB_URL> <browser code> <host> <folder URL> <session id> <long transcript id> [runs]
//
// ROOT is the run-app root whose scratch window approves this browser into the machine lock
// (#3490), as the other walks have it do (walk.py … press "=Compare Digits", then "=Approve"), with
// the page open: the window's card waits for the page to show its digits. Each session is opened
// by its address (#/h/<host>/p/<folder>/s/<id>), as a link to it opens it.
// Pairs once; each run after is a fresh load that connects with the stored key, as opening the
// page does. Prints one line per time, as scripts/perf-window.sh does, and exits 1 when a median
// is over its budget or could not be measured.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [root, webURL, code, host, folder, sessionID, longID, runsArg] = process.argv.slice(2);
if (!root || !webURL || !code || !host || !folder || !sessionID || !longID) {
  console.error("usage: budgets.mjs <ROOT> <WEB_URL> <browser code> <host> <folder URL> <session id> <long transcript id> [runs]");
  process.exit(2);
}
const runs = Number(runsArg ?? 5);
const walkPy = new URL("../../../.agents/skills/run-app/scripts/walk.py", import.meta.url).pathname;
const budgets = JSON.parse(readFileSync(new URL("../../../scripts/perf-budgets.json", import.meta.url), "utf8")).night.web;

const chrome = await launch({ profile: `/tmp/perf-night-chrome-${process.pid}` });
let over = false;
try {
  const page = await chrome.page(`${webURL}#code=${encodeURIComponent(code)}`, { width: 1440, height: 900 });
  await page.waitFor(`performance.getEntriesByName("agents:first-list").length > 0`, 60_000);
  // The Agents section, where the sessions are, so each load after opens on them; it asks for the lock.
  await page.eval(`location.hash = "#/agents"`);
  await new Promise((resolve) => setTimeout(resolve, 2000));
  // This browser into the machine lock: the scratch window compares the digits and approves it.
  const asked = `document.body.innerText.includes("Approve this device on another of your devices.")`;
  for (let i = 0; i < 30 && await page.eval(asked); i++) {
    for (const label of ["=Not now", "=Compare Digits", "=Approve"]) {
      try { execFileSync("python3", [walkPy, root, "press", label], { stdio: "ignore", timeout: 20_000 }); } catch { /* not on screen yet */ }
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  await page.waitFor(`!${asked}`, 10_000);
  // Loaded again as a member of the lock, as the other walks do.
  await page.eval("location.reload()");
  await new Promise((resolve) => setTimeout(resolve, 1500));
  await page.waitFor(`performance.getEntriesByName("agents:first-list").length > 0`, 30_000);
  const url = await page.eval("location.href");

  // The mark's time from the page's start, or its measure's length; -1 when it never came.
  const markAt = (name, kind) => page.eval(`(() => {
    const e = performance.getEntriesByName(${JSON.stringify(`agents:${name}`)}, ${JSON.stringify(kind)}).at(-1);
    return e ? (${JSON.stringify(kind)} === "mark" ? e.startTime : e.duration) : -1;
  })()`);
  // Opens the session by its address, and waits for its chat; the measure's length, or -1.
  const open = async (id) => {
    const before = await page.eval(`performance.getEntriesByName("agents:session-open", "measure").length`);
    await page.eval(`location.hash = ${JSON.stringify(`#/h/${encodeURIComponent(host)}/p/${encodeURIComponent(folder)}/s/${encodeURIComponent(id)}`)}`);
    const came = await page.waitFor(`performance.getEntriesByName("agents:session-open", "measure").length > ${before}`, 30_000)
      .then(() => true, () => false);
    if (!came) return -1;
    const took = await markAt("session-open", "measure");
    await page.eval(`location.hash = "#/agents"`);
    return took;
  };

  const times = { "first list": [], "open a session": [], "open a long transcript": [] };
  for (let i = 0; i < runs; i++) {
    await page.goto("about:blank");
    await page.goto(url);
    await page.waitFor(`performance.getEntriesByName("agents:first-list").length > 0`, 30_000).catch(() => {});
    times["first list"].push(await markAt("first-list", "mark"));
    times["open a session"].push(await open(sessionID));
    times["open a long transcript"].push(await open(longID));
  }

  const median = (values) => {
    const kept = values.filter((v) => v >= 0).sort((a, b) => a - b);
    return kept.length ? Math.round(kept[Math.floor((kept.length - 1) / 2)]) : null;
  };
  for (const [name, values] of Object.entries(times)) {
    const m = median(values);
    const budget = budgets[name];
    const bad = m === null || m > budget;
    over ||= bad;
    console.log(`${bad ? "OVER" : "ok  "} web: ${name.padEnd(29)} median ${String(m ?? "-").padStart(6)} ms  (all: ${values.map(Math.round).join(" ")}; budget ${budget})`);
  }
  console.log(`page errors: ${JSON.stringify(page.errors)}`);
} finally {
  await chrome.close();
}
process.exit(over ? 1 : 0);
