// The #2142 walk: the web console's look on a scratch control plane, its sessions seeded (never a real
// record). The Overview; Machines' sortable table and its side navigation; Machines ▸ Runtimes with its
// breadcrumb; Reports with its Range and By selects; a chat in the console frame; the search and the
// person's menu; the same in the dark; and the bar at a phone's width.
//
//   node Web/test/walk/console2142.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

const chrome = await launch({ profile: `/tmp/run-c2142-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1440, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".top-bar .nav-bar")`, 20_000);

  // The Overview: tabs in the top bar, search, the person; flat cards with their links in their headers.
  await page.waitFor(`document.querySelector(".overview-card-head")`, 30_000);
  check(await page.eval(`!!document.querySelector(".top-search input") && !!document.querySelector(".person-button")`), "the top bar has search and the person");
  check(await page.eval(`document.querySelector(".nav-item.on")?.textContent.startsWith("Overview")`), "Overview is the open tab");
  await pause(1500);
  await page.shot(`${out}/web-overview.png`);

  // Machines: the side navigation, a sortable table.
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelector(".sub-app-row.on") && document.querySelector(".data-table")`, 20_000);
  await pause(1000);
  check(await page.eval(`document.querySelector(".data-table th[aria-sort]")?.textContent.startsWith("Machine")`), "the table is sorted by Machine");
  await page.eval(`[...document.querySelectorAll(".data-table th .sort")].find((b) => b.textContent.startsWith("Machine")).click()`);
  await pause(300);
  check(await page.eval(`document.querySelector(".data-table th[aria-sort]")?.getAttribute("aria-sort") === "descending"`), "pressed again, the other way");
  await page.eval(`[...document.querySelectorAll(".data-table th .sort")].find((b) => b.textContent.startsWith("Machine")).click()`);
  await pause(300);
  await page.shot(`${out}/web-machines.png`);

  // A page one level in: the breadcrumb over its title.
  await page.eval(`location.hash = "#/machines/runtimes"`);
  await page.waitFor(`document.querySelector(".crumbs")?.textContent.includes("Machines")`, 20_000);
  check((await page.text(".crumbs")).replace(/\s+/g, " ").includes("Machines"), "Runtimes' breadcrumb names Machines");
  await pause(1200);
  await page.shot(`${out}/web-runtimes.png`);

  // Reports: Range and By are selects; no segmented control is left.
  await page.eval(`location.hash = "#/reports/spend"`);
  await page.waitFor(`document.querySelector(".choice select")`, 20_000);
  check(await page.eval(`!document.querySelector(".segmented")`), "no segmented control on the page");
  await pause(1500);
  await page.shot(`${out}/web-reports.png`);

  // Usage: its panes are tabs.
  await page.eval(`location.hash = "#/reports/usage"`);
  await page.waitFor(`document.querySelector(".tabs [role=tab][aria-selected=true]")`, 20_000);
  await pause(1200);
  await page.shot(`${out}/web-usage-tabs.png`);

  // A chat in the console frame: Agents › folder › title.
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`document.querySelector(".sidebar .row.folder .disclosure")`, 20_000);
  await page.eval(`document.querySelector(".sidebar .row.folder .disclosure").click()`);
  await page.waitFor(`document.querySelector(".sidebar").textContent.includes("Seeded live agent 1")`, 20_000);
  await page.eval(`(() => {
    const row = [...document.querySelectorAll(".sidebar .row.session")].find((e) => e.textContent.includes("Seeded live agent 1"));
    (row?.matches("button") ? row : row?.querySelector("button"))?.click();
  })()`);
  await page.waitFor(`location.hash.includes("/s/") && document.querySelector(".chat .crumbs")`, 20_000);
  check((await page.text(".chat .crumbs")).startsWith("Agents"), "a chat's breadcrumb starts at Agents");
  await pause(1500);
  await page.shot(`${out}/web-chat.png`);

  // Search: "/" to the field, words find a page.
  await page.eval(`document.activeElement?.blur()`);
  await page.key("/");
  await pause(200);
  check(await page.eval(`document.activeElement === document.querySelector(".top-search input")`), "/ goes to search");
  await page.type("run");
  await page.waitFor(`document.querySelector(".top-search-found li")`, 5_000);
  await pause(300);
  await page.shot(`${out}/web-search.png`);
  await page.key("Enter");
  await page.waitFor(`location.hash.startsWith("#/machines/runtimes")`, 5_000);
  check(true, "Return opens the first found");

  // The person's menu.
  await page.eval(`location.hash = "#/"`);
  await page.waitFor(`document.querySelector(".overview-card-head")`, 20_000);
  await page.eval(`document.querySelector(".person-button").click()`);
  await page.waitFor(`document.querySelector(".person-list")`, 5_000);
  check((await page.text(".person-list")).includes("Forget This Browser"), "Forget This Browser is in the person's menu");
  await pause(300);
  await page.shot(`${out}/web-person-menu.png`);
  await page.key("Escape");

  // The dark.
  await page.raw("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelector(".data-table")`, 20_000);
  await pause(1200);
  await page.shot(`${out}/web-machines-dark.png`);
  await page.eval(`location.hash = "#/"`);
  await page.waitFor(`document.querySelector(".overview-card-head")`, 20_000);
  await pause(1500);
  await page.shot(`${out}/web-overview-dark.png`);
  await page.raw("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] });

  // A phone's width: the section's menu, a search button, the person; a table that scrolls sideways.
  await page.viewport(390, 844);
  await page.eval(`location.hash = "#/machines"`);
  await page.waitFor(`document.querySelector(".data-table")`, 20_000);
  await pause(1000);
  await page.shot(`${out}/web-narrow-machines.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  if (page) console.log(`errors: ${JSON.stringify(page.errors.slice(0, 5))}`);
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
