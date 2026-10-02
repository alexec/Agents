// Open in Browser (#109): a walk's window writes the address it would open to a file in its
// container (ControlConfig.walkOpenedURL); this opens it in headless Chrome on a throwaway
// profile, as the default browser would, and says what came of it. Run once per press, on the
// same profile: the first press should carry #code= and pair, the next open the page plainly.
//
//   node Web/test/walk/openinbrowser.mjs <opened-url file> <chrome profile> <out.png>

import { existsSync, readFileSync, rmSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [file, profile, shot] = process.argv.slice(2);
for (let i = 0; i < 300 && !existsSync(file); i++) await sleep(100);
if (!existsSync(file)) throw new Error(`nothing opened: no ${file}`);
const url = readFileSync(file, "utf8").trim();
rmSync(file);
const carried = new URL(url).hash.startsWith("#code=");
console.log(`opened ${new URL(url).origin}${new URL(url).pathname}, ${carried ? "with a code in the fragment" : "with no code"}`);

const chrome = await launch({ profile });
const page = await chrome.page("about:blank", { width: 1280, height: 800 });
await page.goto(url);
// Paired and open: the footer names the browser.
await page.waitFor(`document.body.innerText.includes("Chrome on")`, 20_000);
const address = await page.eval("location.href");
const back = await page.eval("history.length");
const footer = await page.eval(`[...document.querySelectorAll("footer, .footer")].map((e) => e.innerText).join(" | ")`);
await page.shot(shot);
await chrome.close();

console.log(`address now: ${address}`);
console.log(`history entries in the tab: ${back}`);
console.log(`footer: ${footer.replace(/\s+/g, " ").slice(0, 160)}`);
console.log(`a code in the address now: ${address.includes("code=")}`);
console.log(`a code in any request URL: ${page.requests.some((u) => u.includes("code="))} (${page.requests.length} requests)`);
console.log(`a code in the console: ${page.console.some((line) => line.includes("agents-control"))} (${page.console.length} lines)`);
console.log(`errors: ${page.errors.length ? page.errors.join(" | ") : "none"}`);
