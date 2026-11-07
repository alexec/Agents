// The #3548 walk: a secret for this session only on the page. Pairs, opens the session whose agent asked for
// a secret, shoots its card, ticks "For this session only" and shoots it again; with `settings`, opens
// Settings and shoots For One Session and its Add for a Session… sheet. Each shot is cut to what it shows.
// The browser joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY).
//
//   node Web/test/walk/sessionSecrets3548.mjs <WEB_URL> <browser code> <out dir> <folder> <agent id> [settings]

import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, folder, agent, settings] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-s3548-chrome-${process.pid}` });
let page;

/** Shoots the page, then cuts it to the element `selector` finds, with a margin. */
const shoot = async (name, selector) => {
  await page.eval(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({ block: "center" })`);
  await sleep(500);
  const r = await page.eval(`(() => { const b = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
    const s = devicePixelRatio; return [b.x, b.y, b.width, b.height].map((n) => Math.round(n * s)); })()`);
  const path = `${out}/${name}.png`;
  await page.shot(path);
  const [x, y, w, h] = r, m = 12;
  execFileSync("sips", ["-c", String(h + 2 * m), String(w + 2 * m), "--cropOffset", String(Math.max(0, y - m)), String(Math.max(0, x - m)), path, "--out", path]);
};

try {
  page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 20_000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(2000);
  if (await page.eval(`document.body.innerText.includes("Approve this device on another of your devices.")`)) {
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
    // What it read before it was in the lock was refused: read it all again.
    await page.eval(`location.reload()`);
    await sleep(1000);
    await page.waitFor(`document.body.innerText.includes("Agents")`, 20_000);
  }
  if (settings) {
    await page.eval(`location.hash = "#/setup/secrets"`);
    const section = `section[aria-labelledby=settings-session-secrets]`;
    await page.waitFor(`document.querySelector(${JSON.stringify(section)})?.innerText.includes("Add for a Session")`, 30_000);
    await shoot("web-settings", section);
    await page.press("Add for a Session…");
    await page.waitFor(`document.querySelector("dialog[open], .sheet-body")`, 10_000);
    await shoot("web-settings-add", ".sheet-body");
  } else {
    await page.eval(`location.hash = ${JSON.stringify(`#/h/mac/p/${encodeURIComponent(`file://${folder}`)}/s/${agent}`)}`);
    await page.waitFor(`document.querySelector("p.secret")`, 30_000);
    const card = `(document.querySelector("p.secret").closest("article, section, .card, form, div.question") ?? document.querySelector("p.secret").parentElement)`;
    await page.eval(`${card}.setAttribute("data-walk", "card")`);
    await shoot("web-card", "[data-walk=card]");
    await page.eval(`(() => { const box = [...document.querySelectorAll("label.check")].find((l) => l.innerText.includes("For this session only")).querySelector("input"); box.click(); })()`);
    await page.focus("input[type=password]");
    await page.type("scratch-pass-3548");
    await sleep(300);
    await shoot("web-card-session-only", "[data-walk=card]");
  }
} catch (error) {
  await page?.shot(`${out}/web-failed.png`);
  throw error;
} finally {
  await chrome.close();
}
