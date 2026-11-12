// The #4555 walk of Reports ▸ Planning's Delivery row on a scratch control plane whose store holds a machine's
// lineage nodes and links (v1/lineage/<host>.json, v1/lineage-graph/<host>/links.json): a card a figure, a row a
// repo, or the empty line. Shots go to <out dir>/web-<state>.png.
//
//   node Web/test/walk/delivery4555.mjs <WEB_URL> <browser code> <out dir> <state> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, state, width = "1300"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".reports-pane")`;

const chrome = await launch({ profile: `/tmp/run-r4555-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  await page.eval(`location.hash = "#/reports/value"`);
  // The seeded machine has no person here, so only an admin's organisation scope has it.
  await page.waitFor(`document.querySelector(".report-scopes select")`, 20_000);
  await page.eval(`(() => { const s = document.querySelector(".report-scopes select");
    s.value = [...s.options].find((o) => o.value !== "me")?.value ?? s.value; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await new Promise((r) => setTimeout(r, 1500));
  await page.waitFor(`${pane}?.textContent.includes("Delivery")`, 20_000);
  const said = (await page.text(".reports-pane")).replace(/\s+/g, " ");
  if (state === "empty") {
    check(said.includes("No pull request merged in the last 4 weeks"), `the empty line: ${said.slice(0, 200)}`);
  } else {
    const cards = await page.eval(`document.querySelectorAll(".delivery-card").length`);
    check(cards % 8 === 0 && cards > 0, `a card a figure: ${cards}`);
    check(said.includes("Lead time for changes") && said.includes("CI time to green") && said.includes("DORA:"), "the figures and a band");
    check(said.includes("Bands are DORA’s, from teams of people; agents merge many small PRs"), "the note");
    await page.eval(`[...document.querySelectorAll(".reports-pane h3")].find((h) => h.textContent === "Delivery")?.scrollIntoView({ block: "start" })`);
  }
  // The repo is public: the control plane is named for this Mac (its title, the organisation scope), so the shot
  // says "Scratch" there.
  await page.eval(`(() => { const top = document.querySelector("header, nav");
    const first = document.createTreeWalker(top ?? document.body, NodeFilter.SHOW_TEXT);
    let name = ""; for (let n = first.nextNode(); n && !name; n = first.nextNode()) name = n.textContent.trim();
    if (!name) return;
    const all = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = all.nextNode(); n; n = all.nextNode()) if (n.textContent.includes(name)) n.textContent = n.textContent.replaceAll(name, "Scratch");
    for (const o of document.querySelectorAll("option")) if (o.text.includes(name)) o.text = o.text.replaceAll(name, "Scratch"); })()`);
  await page.shot(`${out}/web-${state}.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
