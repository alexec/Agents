// The #4160 walk on a scratch root: Settings ▸ You ▸ Accounts with each row's last 4, its age line and the
// not-backed-up warning. Adds two secrets and four accounts (scratch values), edits one, and shoots the list.
// With `shoot`, only pairs and shoots (the accounts are there already). Screenshots go to <out dir>. The browser
// joins the scratch root's lock with the recovery key its window showed (RECOVERY_KEY), when it asks.
//
//   node Web/test/walk/accountInfo4160.mjs <WEB_URL> <browser code> <out dir> [shoot]

import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, only] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-a4160-chrome-${process.pid}` });
let page;

/** Shoots the page, then cuts it to the element `selector` finds, with a margin. */
const shoot = async (name, selector) => {
  await page.eval(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({ block: "start" })`);
  await sleep(500);
  const r = await page.eval(`(() => { const b = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
    const s = devicePixelRatio; return [b.x, b.y, b.width, b.height].map((n) => Math.round(n * s)); })()`);
  const path = `${out}/${name}.png`;
  await page.shot(path);
  const [x, y, w, h] = r, m = 12;
  execFileSync("sips", ["-c", String(h + 2 * m), String(w + 2 * m), "--cropOffset", String(Math.max(0, y - m)), String(Math.max(0, x - m)), path, "--out", path]);
};

const shows = (text) => page.eval(`document.body.innerText.includes(${JSON.stringify(text)})`);

const addSecret = async (name, value) => {
  if (await page.eval(`[...document.querySelectorAll(".user-secret code")].some((c) => c.innerText === ${JSON.stringify(name)})`)) return;
  await page.press("Add a Secret…");
  await page.waitFor(`document.querySelector("input[aria-label=Name]")`);
  await sleep(500);
  await page.focus("input[aria-label=Name]");
  await page.type(name);
  await page.focus("input[aria-label=Value]");
  await page.type(value);
  await page.eval(`document.querySelector("form.sheet-body").requestSubmit()`);
  await page.waitFor(`[...document.querySelectorAll(".user-secret code")].some((c) => c.innerText === ${JSON.stringify(name)})`, 20_000);
};

/** Fills the open account sheet's fields and saves it. */
const fill = async (fields) => {
  await page.waitFor(`document.querySelector("input[aria-label=Service]")`);
  await sleep(500);
  for (const [label, value] of Object.entries(fields)) {
    await page.eval(`(() => { const f = document.querySelector("input[aria-label='${label}']"); f.focus(); f.select(); })()`);
    await page.type(value);
  }
  await page.eval(`document.querySelector("form.sheet-body").requestSubmit()`);
  await page.waitFor(`!document.querySelector("input[aria-label=Service]")`, 20_000);
};

const addAccount = async (fields) => {
  if (await shows(fields.Service)) return;
  await page.press("Add Account…");
  await fill(fields);
};

try {
  page = await chrome.page(webURL, { width: 1280, height: 1100 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.innerText.includes("Settings")`, 30_000);
  await sleep(2000);
  if (await shows("Approve this device on another of your devices.")) {
    await page.press("Use Recovery Key");
    await page.waitFor(`document.querySelector("#lock-recovery-key")`);
    await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
    await page.type(process.env.RECOVERY_KEY ?? "");
    await page.press("Use");
    await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
    await page.eval(`location.reload()`);
    await sleep(1500);
  }
  if (!only) {
    await page.eval(`location.hash = "#/setup/secrets"`);
    await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add a Secret…")`, 20_000);
    await addSecret("GITLAB_TOKEN", "scratch-token-4160-not-real-ab12");
    await addSecret("AWS_SECRET_KEY", "scratch-key-4160-not-real-Zq9w");
  }
  await page.eval(`location.hash = "#/setup/accounts"`);
  await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add Account…")`, 20_000);
  if (!only) {
    await addAccount({ Service: "gitlab.com", Address: "agentstest@example.com", Plan: "Free", Secret: "GITLAB_TOKEN",
      Made: "2026-10-31", "Token expires": "2027-01-15" });
    await addAccount({ Service: "aws.amazon.com", Address: "alex@example.com", Plan: "Pay as you go", "Monthly cost (USD)": "4",
      Secret: "AWS_SECRET_KEY", Made: "2026-11-06" });
    await addAccount({ Service: "slack.com", Address: "alex@example.com", Plan: "Pro", Made: "2026-10-10" });
    await addAccount({ Service: "digitalocean.com", Address: "alex@example.com", Plan: "Free", Secret: "DO_TOKEN", Made: "2026-11-01" });
    // An Edit… is Edited.
    const i = await page.eval(`[...document.querySelectorAll(".user-secret")].findIndex((li) => li.innerText.startsWith("aws.amazon.com"))`);
    await page.eval(`document.querySelectorAll(".user-secret")[${i}].querySelector("button").click()`);
    await fill({ Plan: "Business" });
  }
  // The machine opens its copies and sends their hints after its next sync.
  await page.waitFor(`document.body.innerText.includes("••••ab12")`, 90_000).catch(() => {});
  await sleep(1000);
  // A scratch root's machine has this Mac's own name: the shots say "scratch-mac" in its place.
  if (process.env.MACHINE_NAME) {
    await page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n = w.nextNode(); n; n = w.nextNode()) n.nodeValue = n.nodeValue.replaceAll(${JSON.stringify(process.env.MACHINE_NAME)}, "scratch-mac"); })()`);
  }
  await shoot(only ? "web-accounts-used" : "web-accounts", "section[aria-labelledby=settings-accounts]");
} catch (error) {
  await page?.shot(`${out}/web-failed.png`);
  throw error;
} finally {
  await chrome.close();
}
