// The #3230 walk: Settings ▸ Agents ▸ Policy on the page with a policy-yours.json signed on another Mac (the root
// seeded with one before its host starts), then Sign with This Mac’s Key, and the rules applied.
//
//   node Web/test/walk/policy3230.mjs <WEB_URL> <page browser code> <out dir> <chrome profile>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, pageCode, out, profile] = process.argv.slice(2);
const top = (id) => `document.getElementById(${JSON.stringify(id)})?.scrollIntoView({ block: "start" })`;
const chrome = await launch({ profile });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/settings/settings/policy"`);
  await page.waitFor(`document.querySelector(".policy-untrusted")`, 20_000);
  await sleep(1000);
  await page.eval(top("settings-agents-policy"));
  await sleep(500);
  await page.shot(`${out}/web-signed-on-another-mac.png`);
  console.log("untrusted:", await page.eval(`document.querySelector(".policy-untrusted")?.innerText`));
  await page.press("Sign with This Mac’s Key");
  await page.waitFor(`!document.querySelector(".policy-untrusted")`, 20_000);
  await sleep(1000);
  await page.eval(top("settings-agents-policy"));
  await sleep(500);
  await page.shot(`${out}/web-signed-here.png`);
  console.log("mode:", await page.eval(`document.getElementById("policy-permissionMode").value`));
} finally {
  await chrome.close();
}
