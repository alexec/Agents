// The #114 and #115 walk, on a scratch root: the page loads in Chrome with no CSP complaint,
// Chrome DevTools' probe is answered 404 by the listener, and a fresh control plane's empty
// projects column adds a project by Add Folder… (browsing the host's folders) and by Clone
// Git URL…, each then listed by the host. Screenshots go to <out dir>.
//
//   node Web/test/walk/addproject.mjs <WEB_URL> <browser code> <folder to add> <out dir> [git URL]
//
// A clone lands in the host account's real home folder (`~/<name>`), scratch root or not: give a
// git URL only when that folder doesn't exist, and remove it afterwards.

import { launch } from "./cdp.mjs";

const [webURL, code, folder, out, cloneURL] = process.argv.slice(2);
const origin = new URL(webURL).origin;
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };

// 1. DevTools' probe, as Chrome sends it: from the browser, not the page, so CSP is not asked.
const probe = await fetch(`${origin}/.well-known/appspecific/com.chrome.devtools.json`);
const csp = probe.headers.get("content-security-policy") ?? "";
check(probe.status === 404 && (await probe.text()) === "", `the devtools probe is ${probe.status}, empty`);
check(/connect-src ws:\/\/localhost:\d+;/.test(csp) && !/connect-src[^;]*http/.test(csp),
  `connect-src is still the one WebSocket: ${csp.match(/connect-src[^;]*/)?.[0]}`);

const chrome = await launch({ profile: `/tmp/addproject-chrome-${process.pid}` });
say(`browser: ${await chrome.version()}`);
const page = await chrome.page(webURL);

// 2. Pair, and the empty column says what to do.
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`document.body.innerText.includes("No projects yet")`, 20_000);
check(true, `paired: ${JSON.stringify(await page.text(".empty-projects"))}`);
await page.shot(`${out}/addproject-1-empty.png`);

// 3. The + menu at the head of the projects column.
await page.press("New project");
await page.waitFor(`document.querySelector("[role=menu][aria-label='New project']")`);
say(`menu: ${JSON.stringify(await page.text("[role=menu][aria-label='New project']"))}`);
await page.shot(`${out}/addproject-2-menu.png`);

// 4. Add Folder…: the host's home, then the folder typed in, then Add as project.
await page.press("Add Folder…");
await page.waitFor(`document.querySelector("dialog.sheet[open] .folder-row")`);
say(`dialog: ${JSON.stringify((await page.text("dialog.sheet")).split("\n").slice(0, 2))}`);
await page.shot(`${out}/addproject-3-browse-home.png`);
await page.eval(`(() => { const f = document.querySelector("dialog.sheet input"); f.value = ""; f.focus(); })()`);
await page.type(folder.replace(/\/[^/]+\/?$/, ""));
await page.eval(`document.querySelector("dialog.sheet form").requestSubmit()`);
const name = folder.replace(/\/+$/, "").split("/").pop();
await page.waitFor(`[...document.querySelectorAll("dialog.sheet .folder-row")].some((b) => b.textContent === ${JSON.stringify(name)})`);
await page.eval(`[...document.querySelectorAll("dialog.sheet .folder-row")].find((b) => b.textContent === ${JSON.stringify(name)}).click()`);
await page.shot(`${out}/addproject-4-browse-chosen.png`);
await page.press("Add as project");
await page.waitFor(`[...document.querySelectorAll(".projects .row.project .title")].some((t) => t.textContent === ${JSON.stringify(name)})`);
check(true, `added ${name}: the column lists ${JSON.stringify(await page.text(".projects .scroll"))}`);
check(decodeURIComponent(await page.eval("location.hash")).includes(name), `and it is chosen: ${await page.eval("location.hash")}`);
await page.shot(`${out}/addproject-5-added.png`);

// 5. Clone Git URL…, when given one.
if (cloneURL) {
  await page.press("New project");
  await page.press("Clone Git URL…");
  await page.waitFor(`document.querySelector("dialog.sheet[open] input")`);
  await page.focus("dialog.sheet input");
  await page.type("not a url");
  say(`refused: ${JSON.stringify(await page.text("dialog.sheet .sheet-note"))}`);
  await page.eval(`(() => { const f = document.querySelector("dialog.sheet input"); f.value = ""; f.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.type(cloneURL);
  say(`taken: ${JSON.stringify(await page.text("dialog.sheet .sheet-note"))}`);
  await page.shot(`${out}/addproject-6-clone.png`);
  await page.press("Clone");
  const cloned = cloneURL.replace(/\/+$/, "").split(/[/:]/).pop().replace(/\.git$/, "");
  await page.waitFor(`document.querySelector(".projects .row.cloning")`, 10_000);
  await page.shot(`${out}/addproject-7-cloning.png`);
  await page.waitFor(`[...document.querySelectorAll(".projects .row.project:not(.cloning) .title")].some((t) => t.textContent === ${JSON.stringify(cloned)})`, 120_000);
  check(true, `cloned ${cloned}: the column lists ${JSON.stringify(await page.text(".projects .scroll"))}`);
  await page.shot(`${out}/addproject-8-cloned.png`);
}

// 6. Nothing the page did drew a complaint from the browser.
check(page.errors.length === 0, `browser errors: ${JSON.stringify(page.errors)}`);
say(`console: ${JSON.stringify(page.console)}`);
await chrome.close();
say(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
