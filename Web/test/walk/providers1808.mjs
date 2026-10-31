// The #1808 walk: Settings ▸ Machine providers on a scratch control plane that has a fake
// commands provider (two workspaces, their state in files). Lists it, links the scratch host to
// the workspace of its name, starts and stops it, unlinks it, opens Add a Provider and Edit, and
// adds a DigitalOcean provider with a token that is not one, which the control plane refuses.
// Screenshots go to <out dir>.
//
//   node Web/test/walk/providers1808.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const section = `document.querySelector("[aria-labelledby=settings-providers]")`;

const chrome = await launch({ profile: `/tmp/run-prov1808-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  // Every confirm (Remove, Unlink, Stop with agents at work) is said yes to.
  await page.onNewDocument("window.confirm = () => true;");
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);

  await page.goto(`${new URL(webURL).origin}/#/settings`);
  // A hash change loads no new document: say yes to every confirm in this one too.
  await page.eval("window.confirm = () => true");
  await page.waitFor(`${section}?.textContent.includes("Fake machines")`, 15_000);
  await page.waitFor(`${section}.textContent.includes("Listed")`, 15_000);
  // A run before may have left the host linked.
  if (await page.eval(`${section}.textContent.includes("linked to")`)) {
    await page.press("Unlink");
    await page.waitFor(`!${section}.textContent.includes("linked to")`, 15_000);
  }
  const listed = (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ");
  check(listed.includes("Alexs-MacBook-Air") && listed.includes("scratch-2") && listed.includes("not a host"), `listed: ${listed.slice(0, 400)}`);
  await page.shot(`${out}/web-1-providers.png`);

  // Link to Host: the workspace named as the host offers it first.
  const linkName = await page.eval(`[...${section}.querySelectorAll("button")].map((b) => b.textContent).find((t) => t.startsWith("Link to")) ?? ""`);
  check(linkName.length > 0, `link button: ${linkName}`);
  await page.press(linkName);
  await page.waitFor(`document.querySelector("dialog[open]")`);
  await page.shot(`${out}/web-2-link.png`);
  await page.press("Link");
  await page.waitFor(`${section}.textContent.includes("linked to")`, 15_000);
  check(true, "linked");

  // Start, then Stop: the fake's files say running, then stopped.
  await page.waitFor(`[...${section}.querySelectorAll("button")].some((b) => b.textContent === "Start" || b.textContent === "Stop")`, 15_000);
  const first = await page.eval(`[...${section}.querySelectorAll("button")].find((b) => b.textContent === "Start" || b.textContent === "Stop").textContent`);
  await page.shot(`${out}/web-3-linked.png`);
  await page.press(first);
  const other = first === "Start" ? "Stop" : "Start";
  await page.waitFor(`[...${section}.querySelectorAll("button")].some((b) => b.textContent === ${js(other)})`, 30_000).catch(() => null);
  const after = (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ");
  check(after.includes(other), `${first} pressed; now: ${after.slice(0, 300)}`);
  await page.shot(`${out}/web-4-after-${first.toLowerCase()}.png`);

  await page.press("Unlink");
  await page.waitFor(`!${section}.textContent.includes("linked to")`, 15_000);
  check(true, "unlinked");

  // Add a Provider: kind first, then its form.
  await page.press("Add Provider…");
  await page.waitFor(`document.querySelector("dialog[open] [role=radiogroup]")`);
  await page.press("DigitalOcean Droplets");
  await page.waitFor(`document.querySelector("dialog[open] input[type=password]")`);
  await page.focus("dialog[open] input[type=password]");
  await page.type("not-a-token");
  await page.shot(`${out}/web-5-add.png`);
  await page.press("Add");
  await page.waitFor(`document.querySelector("dialog[open] .failure")`, 30_000).catch(() => null);
  const refusal = await page.eval(`document.querySelector("dialog[open] .failure")?.textContent ?? ""`);
  check(refusal.length > 0, `refused: ${refusal}`);
  // The token is in no storage of the page.
  const stored = await page.eval(`JSON.stringify(Object.entries(localStorage)) + JSON.stringify(Object.entries(sessionStorage))`);
  check(!stored.includes("not-a-token"), "the token is not in localStorage or sessionStorage");
  await page.shot(`${out}/web-6-refused.png`);
  await page.press("Cancel");
  await sleep(300);
  check(!(await page.eval(`!!document.querySelector("dialog[open]")`)), "the sheet closed");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
