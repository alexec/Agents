// The #5245 walk of Reports ▸ Planning ▸ Delivery (spec 5239 board 5) on a scratch control plane and host whose
// <root>/lineage-deploys.json holds scratch deploys of example/shop in four environments: production, with too few
// dimmed; every tier; 7 days; a narrow page; and a tier with none. Shots go to <out dir>/web-<state>.png.
//
//   node Web/test/walk/delivery5245.mjs <WEB_URL> <browser code> <out dir> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, width = "1440"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".deploys-page")`;
const said = async (page) => (await page.text(".deploys-page")).replace(/\s+/g, " ");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = await launch({ profile: `/tmp/run-dora5245-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 1100 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  // A fresh scratch set-up (#3492): found the machine lock, skip the recovery key, approve the scratch host.
  const pressed = (words) => page.eval(`(() => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent.trim() === ${JSON.stringify(words)} && !x.disabled);
    if (b) b.click(); return !!b; })()`);
  for (let i = 0, approved = false; i < 40 && !approved; i++) {
    await pressed("Skip");
    if (await pressed("Compare Digits")) await sleep(1000);
    approved = await pressed("Approve");
    await sleep(500);
  }
  await sleep(2000);

  const open = async (query) => {
    await page.eval(`location.hash = ${JSON.stringify(`#/reports/value/delivery${query ? `?${query}` : ""}`)}`);
    await sleep(800);
  };

  // Board 5: production, the last 30 days.
  await open("");
  await page.waitFor(`${pane}?.querySelectorAll(".deploys-target").length >= 3 && !${pane}.textContent.includes("Still asking")`, 30_000);
  let text = await said(page);
  check(text.includes("Last update"), "Last update at the top");
  check(text.includes("The last 30 days · Tier: production"), "the range and the tier");
  check(text.includes("example/shop @ production") && text.includes("example/shop @ github-pages"), "a block for each production target");
  check(!text.includes("testflight"), "no testing target on production");
  check(/Deploy frequency.*Lead time for changes.*Change failure rate.*Time to restore/.test(text), "the four tiles in DORA's order");
  check(text.includes("a day"), "the docs' frequency is a day");
  check(text.includes("Too few deploys for a figure that means much (3); shown dimmed."), "the app store dimmed");
  check(await page.eval(`[...document.querySelectorAll(".sub-app-row.under")].some((b) => b.textContent.trim() === "Delivery" && b.classList.contains("on"))`),
    "Delivery under Planning, chosen");
  await page.shot(`${out}/web-production.png`);

  // Every tier: testflight too.
  await open("range=month&tier=all");
  await page.waitFor(`${pane}?.textContent.includes("example/shop @ testflight")`, 20_000);
  check((await said(page)).includes("Tier: every tier"), "every tier");
  await page.shot(`${out}/web-every-tier.png`);

  // The last 7 days.
  await open("range=week&tier=production");
  await page.waitFor(`${pane}?.textContent.includes("in 7 days")`, 20_000);
  await page.shot(`${out}/web-week.png`);

  // A tier with none: the empty line names the others.
  await open("range=month&tier=staging");
  await page.waitFor(`${pane}?.textContent.includes("No deploy to a staging environment")`, 20_000);
  text = await said(page);
  check(text.includes("choose Every tier to see them"), `the empty line: ${text.slice(0, 160)}`);
  await page.shot(`${out}/web-empty.png`);

  // Planning's Delivery row links here.
  await page.eval(`location.hash = "#/reports/value"`);
  await page.waitFor(`[...document.querySelectorAll("a")].some((a) => a.textContent.includes("The DORA figures of each environment"))`, 20_000);
  check(true, "Planning links to the page");

  // A narrow page.
  const narrow = await chrome.page(`${webURL}#/reports/value/delivery`, { width: 400, height: 1400 });
  await narrow.waitFor(`document.querySelectorAll(".deploys-target").length >= 3`, 30_000);
  await narrow.shot(`${out}/web-narrow.png`);
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} FAILED` : "all ok");
process.exit(failed ? 1 : 0);
