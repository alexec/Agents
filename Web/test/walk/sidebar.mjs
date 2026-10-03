// The #151 walk: the page's one sidebar beside the window's (#145, specs/145-one-sidebar/walks/).
// Pairs, then shoots the shapes the window's walk shot, the keys and the menus, and the widths.
//
//   node Web/test/walk/sidebar.mjs <WEB_URL> <browser code> <out dir> [offline]
//
// With `offline`, only waits (up to 3 minutes) for a server to be said offline at the sidebar's
// foot, and shoots it: pause the server's agentsd with SIGSTOP first, and resume it after.
//
// Expects a root seeded as the window's walk was: Agents (Needs you ×2, Done with unread, Paused,
// archived, two workflows), website, infra-tools on this Mac, and api-server on a server.

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, mode = ""] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const chrome = await launch({ profile: `/tmp/151-sidebar-chrome-${process.pid}` });
const js = JSON.stringify;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= ${mode === "offline" ? 3 : 4}`, 20_000);
  await sleep(800);
  if (mode === "offline") {
    await page.waitFor(`document.querySelector(".sidebar-foot .foot-line")`, 180_000);
    await sleep(500);
    say(`foot: ${await page.eval(`document.querySelector(".sidebar-foot").innerText.replace(/\\s+/g, " ")`)}`);
    await page.shot(`${out}/14-server-offline.png`);
    await chrome.close();
    process.exit(0);
  }

  const projects = () => page.eval(`[...document.querySelectorAll(".sidebar .row.project")].map((r) => r.innerText.replace(/\\s+/g, " ").trim())`);
  const rows = () => page.eval(`[...document.querySelectorAll(".sidebar .activity-row")].map((r) => r.innerText.replace(/\\s+/g, " ").trim())`);
  const unfold = (name, open = true) => page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.project .disclosure")].find((d) => d.getAttribute("aria-label").endsWith(" " + ${js(name)}));
    if (b && (b.getAttribute("aria-expanded") === "true") !== ${open}) b.click();
    return !!b;
  })()`);
  const clickTitle = (selector, text) => page.eval(`(() => {
    const el = [...document.querySelectorAll(${js(selector)})].find((e) => e.querySelector(".title")?.textContent.includes(${js(text)}));
    (el?.matches("button") ? el : el?.querySelector("button"))?.click();
    return !!el;
  })()`);
  const focused = () => page.eval(`document.activeElement?.innerText?.split("\\n")[0] ?? ""`);
  const hash = () => page.eval(`location.hash`);
  const key = (k, extra = {}) => page.eval(`document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: ${js(k)}, bubbles: true, cancelable: true, ...${js(extra)} }))`);

  // 1: every project folded, nothing selected.
  await page.eval(`localStorage.removeItem("agents.sidebar.folds")`);
  await page.eval(`location.hash = "#/"`);
  await sleep(300);
  say(`activity: ${js(await rows())}`);
  say(`projects folded: ${js(await projects())}`);
  await page.shot(`${out}/1-folded-nothing-selected.png`);

  // 2: Agents and the server's api-server unfolded.
  await unfold("Agents");
  await unfold("build-box:api-server");
  await sleep(600);
  say(`projects unfolded: ${js(await projects())}`);
  say(`subheads: ${js(await page.eval(`[...document.querySelectorAll(".sidebar .fold-body .subhead")].map((h) => h.innerText.replace(/\\s+/g, " ").trim())`))}`);
  await page.shot(`${out}/2-unfolded.png`);

  // 3: a session picked.
  await clickTitle(".sidebar .row.session", "Fix the login redirect");
  await page.waitFor(`document.querySelector(".chat .prompt, .chat textarea")`, 10_000).catch(() => {});
  await sleep(500);
  say(`session: ${await hash()}`);
  await page.shot(`${out}/3-session-selected.png`);

  // 4: a project picked opens its Dashboard; only its own row lights.
  await page.eval(`[...document.querySelectorAll(".sidebar .row.project .pick")].find((b) => b.innerText.startsWith("Agents")).click()`);
  await page.waitFor(`document.querySelector(".dashboard-page")`, 10_000);
  await sleep(500);
  say(`project: ${await hash()}; lit: ${js(await page.eval(`[...document.querySelectorAll(".sidebar .chosen")].map((e) => e.innerText.split("\\n")[0])`))}`);
  await page.shot(`${out}/4-project-dashboard.png`);

  // 5: reloaded, the folds are kept.
  await page.eval(`location.hash = "#/"; location.reload()`);
  await page.waitFor(`document.querySelectorAll(".sidebar .row.project").length >= 4`, 20_000);
  await sleep(800);
  say(`after reload: ${js(await page.eval(`[...document.querySelectorAll(".sidebar .row.project .pick")].map((b) => b.innerText.split("\\n")[0] + (b.getAttribute("aria-expanded") === "true" ? " (open)" : ""))`))}`);
  await page.shot(`${out}/5-reloaded-folds-kept.png`);

  // 6: Archived sessions opened under Agents.
  await page.eval(`document.querySelector(".sidebar details.archived > summary").click()`);
  await sleep(800);
  await page.shot(`${out}/6-archived.png`);
  say(`archived: ${js(await page.eval(`document.querySelector(".sidebar details.archived").innerText.replace(/\\s+/g, " ")`))}`);

  // 7: a workflow picked.
  await page.eval(`document.querySelector(".sidebar .row.workflow .pick").click()`);
  await page.waitFor(`document.querySelector(".workflow-page")`, 10_000).catch(() => {});
  await sleep(500);
  say(`workflow: ${await hash()}`);
  await page.shot(`${out}/7-workflow-selected.png`);

  // 8: the Activity pages.
  for (const name of ["events", "resources", "runtimes", "spending"]) {
    await page.eval(`[...document.querySelectorAll(".sidebar .activity-row")].find((r) => r.innerText.toLowerCase().includes(${js(name === "spending" ? "" : name)}) && (${js(name)} !== "spending" || r === document.querySelectorAll(".sidebar .activity-row")[3])).click()`);
    await sleep(700);
    say(`${name}: ${await hash()} · ${js(await page.eval(`document.querySelector(".activity-page")?.innerText.replace(/\\s+/g, " ").slice(0, 160)`))}`);
    if (name === "events" || name === "runtimes") await page.shot(`${out}/8-activity-${name}.png`);
  }

  // 9: the keys. Focus on Events; ↓ to Resources; then down into the projects.
  await page.eval(`location.hash = "#/"`);
  await sleep(300);
  await page.eval(`document.querySelector(".sidebar .activity-row").focus()`);
  const walk = [];
  for (let i = 0; i < 5; i++) { await key("ArrowDown"); await sleep(150); walk.push(`${await focused()} ${await hash()}`); }
  say(`↓×5: ${js(walk)}`);
  // On "Agents" (unfolded): ← folds it, → unfolds it.
  await page.eval(`[...document.querySelectorAll(".sidebar .row.project .pick")].find((b) => b.innerText.startsWith("Agents")).focus()`);
  await key("ArrowLeft");
  await sleep(200);
  const folded = await page.eval(`[...document.querySelectorAll(".sidebar .row.project .pick")].find((b) => b.innerText.startsWith("Agents")).getAttribute("aria-expanded")`);
  await page.shot(`${out}/9-keys-folded.png`);
  await key("ArrowRight");
  await sleep(200);
  const unfolded = await page.eval(`[...document.querySelectorAll(".sidebar .row.project .pick")].find((b) => b.innerText.startsWith("Agents")).getAttribute("aria-expanded")`);
  say(`← then →: expanded ${folded} then ${unfolded}`);
  await key("ArrowDown");
  await sleep(300);
  say(`↓ into Agents: ${await focused()} ${await hash()}`);
  await key("ArrowLeft");
  await sleep(150);
  say(`← from a session: ${await focused()}`);

  // 10: the menus. A session row's, by the menu key; a project row's, by a right click.
  await page.eval(`[...document.querySelectorAll(".sidebar .row.session")].find((r) => r.innerText.includes("Dock badge counts")).focus()`);
  await key("ContextMenu");
  await sleep(200);
  say(`session menu: ${js(await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].map((b) => b.textContent)`))}`);
  await page.shot(`${out}/10-session-menu.png`);
  const marked = await page.eval(`(() => {
    const b = [...document.querySelectorAll(".context-menu [role=menuitem]")].find((e) => e.textContent.startsWith("Mark as"));
    b.click();
    return b.textContent;
  })()`);
  await sleep(800);
  say(`after ${marked}: ${js(await page.eval(`[...document.querySelectorAll(".sidebar .fold-body .subhead")].map((h) => h.innerText.replace(/\\s+/g, " ").trim()).filter((t) => t.startsWith("Done"))`))}`);
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.project .pick")].find((e) => e.innerText.startsWith("website"));
    const box = b.getBoundingClientRect();
    b.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 10 }));
  })()`);
  await sleep(200);
  say(`project menu: ${js(await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].map((b) => b.textContent)`))}`);
  await page.shot(`${out}/11-project-menu.png`);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "New Session").click()`);
  await sleep(600);
  say(`New Session: ${await hash()}`);
  await page.shot(`${out}/12-new-session.png`);

  // 13: the widths. 1600 with files is the window's wide; 1000 the medium; 390 a phone.
  await page.eval(`location.hash = "#/"`);
  for (const [w, h] of [[1600, 900], [1000, 800], [760, 800], [390, 844]]) {
    await page.viewport(w, h);
    await sleep(400);
    const visible = await page.eval(`["sidebar","projects","sessions","chat"].filter((c) => { const el = document.querySelector("." + c); return el && el.offsetParent !== null; })`);
    const sideways = await page.eval(`document.documentElement.scrollWidth > innerWidth + 1`);
    say(`${w}×${h}: ${js(visible)}${sideways ? " — scrolls sideways" : ""}`);
    await page.shot(`${out}/13-width-${w}.png`);
  }
  const errors = await page.eval(`(window.__errors ?? []).length`).catch(() => 0);
  say(`errors on the page: ${errors}`);
} finally {
  if (mode !== "offline") writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
  await chrome.close();
}
