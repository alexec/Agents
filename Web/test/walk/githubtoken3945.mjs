// The #3945 walk on a scratch root: the Connect GitHub sheet on the github.com way (the default),
// on its second way, Personal access token, with what the person gives up, and an App's token,
// which the host refuses before it asks github.com. The host has no GitHub connection at the start.
// Screenshots go to <out dir>. The browser joins the scratch root's lock with the recovery key its
// window showed (RECOVERY_KEY), when it asks.
//
//   node Web/test/walk/githubtoken3945.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
// A field's value, as a person types it: Preact reads it from the input event.
const fill = (selector, value) => `(() => { const i = document.querySelector(${JSON.stringify(selector)});
  i.value = ${JSON.stringify(value)}; i.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`;

const chrome = await launch({ profile: `/tmp/gh3945-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1300, height: 900 });

await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(code);
await page.press("Connect");
await page.waitFor(`[...document.querySelectorAll("a, button")].some((e) => e.textContent.trim() === "Agents")`, 20_000);
const asked = `document.body.innerText.includes("Approve this device on another of your devices.")`;
/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
const joinLock = async () => {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
};

await joinLock();
await page.goto(`${new URL(webURL).origin}/#/a/mcp`);
await page.waitFor(has("Connect GitHub…"), 15_000).catch(async (e) => {
  await page.shot(`${out}/web-failed.png`);
  say(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 600)}`);
  throw e;
});
await page.press("Connect GitHub…");
await page.waitFor(has("Continue on github.com"), 5_000);
check(await page.eval(has("Personal access token")), "the sheet offers Personal access token beside github.com");
await page.shot(`${out}/web-sign-in.png`);

await page.press("Personal access token");
await page.waitFor(has("Make a Token on GitHub"), 5_000);
check(await page.eval(has("all the rights you give it")), "the token way says what the person gives up");
await page.shot(`${out}/web-token.png`);

await page.eval(fill(".token-form input[type=password]", "ghu_scratch"));
// The sheet's own Connect, not the Connections row's Connect GitHub… behind it.
await page.eval(`document.querySelector("button[type=submit][form=connect-token]").click()`);
await page.waitFor(has("an App's token"), 10_000).catch(async (e) => {
  await page.shot(`${out}/web-failed.png`);
  say((await page.text()).replace(/\s+/g, " ").slice(-600));
  await chrome.close();
  throw e;
});
check(true, "an App's token is refused");
await page.shot(`${out}/web-error.png`);

await chrome.close();
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
