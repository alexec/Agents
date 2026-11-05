// The #3535 walk: Settings ▸ Browser on the page. Pairs, opens Settings, shoots the sites, clears one site by
// its own Clear, then all of them (confirmed), and shoots each.
//
//   node Web/test/walk/browser3535.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/3535-browser-chrome-${process.pid}` });
const section = `document.querySelector("section[aria-labelledby=settings-browser]")`;
const shoot = async (name) => {
  await page.eval(`${section}.scrollIntoView()`);
  await sleep(400);
  await page.shot(`${out}/${name}.png`);
};
let page;

try {
  page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`!!${section} && ${section}.innerText.includes("cookie")`, 30_000);
  await shoot("web-sites");
  const site = await page.eval(`${section}.querySelector("button[aria-label^='Clear ']").getAttribute("aria-label")`);
  await page.press(site);
  await page.waitFor(`!${section}.innerText.includes(${JSON.stringify(site.slice("Clear ".length))})`, 20_000);
  await shoot("web-cleared-one");
  await page.eval(`window.confirm = () => true`);
  await page.press("Clear All…");
  await page.waitFor(`${section}.innerText.includes("No sites yet.")`, 20_000);
  await shoot("web-cleared-all");
  console.log("cleared:", site);
} catch (error) {
  await page?.shot(`${out}/web-failed.png`);
  throw error;
} finally {
  await chrome.close();
}
