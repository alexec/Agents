// The #1809 walk: Start a Machine from a Repository on a scratch control plane with a fake
// provider that makes machines (its create only writes the first-boot line to a file in the
// scratch root, never runs it). Opens the + menu's item, refuses an address that is not https,
// takes one that is, shows the provider's form, starts, and says the machine joins and clones.
// Screenshots go to <out dir>.
//
//   node Web/test/walk/machine1809.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const dialog = `document.querySelector("dialog[open]")`;

const chrome = await launch({ profile: `/tmp/run-mach1809-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);

  await page.press("New folder");
  await page.press("Start a Machine from a Repository…");
  await page.waitFor(`${dialog}?.textContent.includes("Fake cloud")`, 15_000);
  await page.waitFor(`${dialog}.textContent.includes("Size")`, 15_000);
  check(true, "the sheet lists the provider and its form");

  await page.focus("dialog[open] input[type=url]");
  await page.type("git@github.com:alexec/agents.git");
  const refused = await page.eval(`${dialog}.querySelector(".failure")?.textContent ?? ""`);
  check(refused.includes("https address"), `an ssh address is refused: ${refused}`);
  check(await page.eval(`${dialog}.querySelector("button[type=submit]").disabled`), "Start is off");
  await page.eval(`(() => { const i = ${dialog}.querySelector("input[type=url]"); i.value = ""; i.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  await page.focus("dialog[open] input[type=url]");
  await page.type("https://github.com/alexec/agents.git");
  await page.waitFor(`${dialog}.textContent.includes("clones alexec/agents")`);
  await page.shot(`${out}/web-1-sheet.png`);
  await page.press("Start");
  await page.waitFor(`${dialog}.textContent.includes("is starting")`, 30_000).catch(() => null);
  const said = (await page.text("dialog[open]")).replace(/\s+/g, " ");
  check(said.includes("joins and clones alexec/agents on its first boot"), `said: ${said.slice(0, 400)}`);
  await page.shot(`${out}/web-2-started.png`);
  await page.press("Done");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
console.log(js({ failed }));
process.exit(failed ? 1 : 0);
