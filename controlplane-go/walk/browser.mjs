// Stage 5 in a real browser (#1126): headless Chrome against the Go control plane's web
// listener, paired with a --browser code through the page's own #code= link (#109).
// Headless, with a profile of its own under /tmp: no window, nothing on the screen, and not
// Alex's Chrome profile.
//
//   node walk/browser.mjs <web url> <browser code> <text the agent list must show> <out dir>
// needs playwright-core (npm i playwright-core, in a scratch folder on NODE_PATH).
import { chromium } from "playwright-core";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [url, code, want, out] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), "cpgo-chrome-"));
const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  viewport: { width: 1280, height: 800 },
});
const page = ctx.pages()[0] ?? (await ctx.newPage());
const log = [];
page.on("console", (m) => log.push(`console.${m.type()}: ${m.text()}`));
page.on("pageerror", (e) => log.push(`pageerror: ${e.message}`));
let frames = 0;
page.on("websocket", (ws) => {
  log.push(`websocket ${ws.url()}`);
  ws.on("framereceived", () => frames++);
  ws.on("close", () => log.push("websocket closed"));
});

const res = await page.goto(url);
log.push(`GET ${url} → ${res.status()} csp=${res.headers()["content-security-policy"] ? "yes" : "no"}`);
await page.screenshot({ path: join(out, "web-1-unpaired.png") });

// A new document, not a hash change: the page reads #code= only as it loads.
await page.goto("about:blank");
await page.goto(`${url}#code=${encodeURIComponent(code)}`);
let ok = false;
try {
  // The agent is in its project's section ("work", its folder), closed at first.
  await page.getByText("Chrome on this Mac").waitFor({ timeout: 30000 });
  await page.getByText("work", { exact: true }).first().click();
  await page.getByText(want, { exact: false }).first().waitFor({ timeout: 30000 });
  ok = true;
} catch (e) {
  log.push(`did not see "${want}": ${e.message.split("\n")[0]}`);
}
await page.screenshot({ path: join(out, "web-2-paired.png") });
if (ok) {
  await page.getByText(want, { exact: false }).first().click();
  await page.waitForTimeout(3000);
  await page.screenshot({ path: join(out, "web-3-agent.png") });
  // A turn from the page: the prompt goes through the Go router to the Mac host.
  await page.getByPlaceholder("What do you want to do?").fill("Answer with the one word pong, and use no tools.");
  await page.keyboard.press("Enter");
  try {
    await page.getByText(/^pong\.?$/i).first().waitFor({ timeout: 120000 });
    log.push("turn from the page: answered pong");
  } catch (e) {
    log.push(`turn from the page: no pong: ${e.message.split("\n")[0]}`);
  }
  await page.screenshot({ path: join(out, "web-3b-turn.png") });
}
// The page keeps its key in IndexedDB: a reload must come back paired, with no code.
await page.reload();
let again = false;
try {
  await page.getByText("Chrome on this Mac").waitFor({ timeout: 30000 });
  await page.getByText(want, { exact: false }).first().waitFor({ timeout: 30000 });
  again = true;
} catch {}
await page.screenshot({ path: join(out, "web-4-reloaded.png") });
log.push(`frames received: ${frames}`);
console.log(log.join("\n"));
console.log(`agent "${want}" shown: ${ok}; after reload: ${again}`);
await ctx.close();
process.exit(ok && again ? 0 : 1);
