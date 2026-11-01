// The #998 slice 2b walk (spec 998 US3, SC-007): sets a policy on a scratch control plane as its
// admin, reads back the marks the machine puts on each list, then walks the page in headless Chrome:
// the new-agent form, Activity ▸ Runtimes and Spending, and, with the kill switch on, the red strip
// and the composer. Leaves the policy set and the kill switch on, for the window's and the Remote's walk.
//
//   node Web/test/walk/policy998.mjs <WEB_URL> <browser code> <browser code> <folder> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const [webURL, setterCode, pageCode, folder, out] = process.argv.slice(2);

/** Pairs as a browser at `base`, then connects again as itself; returns a raw line client. */
async function paired(base, codeText, name) {
  const origin = new URL(base).origin;
  const url = base.replace(/^http/, "ws").replace(/\/$/, "") + "/v1/connect";
  const code = w.parseCode(codeText);
  if (!code) throw new Error("not a client code");
  const keys = new w.MemoryKeyStore();
  let socket = await opened(url, origin);
  await w.pair(linesOf(socket), code, origin, name, async () => {
    const { pair, publicRaw } = await w.makeKeyPair();
    const client = w.newClientID();
    keys.record = { privateKey: pair.privateKey, publicKey: pair.publicKey, client,
      control: w.base64url(code.controlKey), paired: "" };
    return { client, publicRaw };
  }, undefined, "browser");
  socket.close();
  socket = await opened(url, origin);
  const lines = linesOf(socket);
  await w.connect(lines, keys.record, origin, undefined, "browser");
  let id = 0;
  return {
    async ask(method, params = {}, host = null) {
      id += 1;
      const m = { jsonrpc: "2.0", id, method, params };
      socket.send(JSON.stringify(host ? { h: host, m } : { m }));
      for (;;) {
        const frame = JSON.parse(await lines.next(30_000));
        const reply = typeof frame.m === "string" ? JSON.parse(frame.m) : frame.m;
        if (reply?.id === id) return reply.error ? { error: reply.error } : { result: reply.result };
      }
    },
    close() { socket.close(); },
  };
}

function opened(url, origin) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers: { Origin: origin } });
    socket.onopen = () => resolve(socket);
    socket.onerror = (event) => reject(new Error(`could not open ${url}: ${event.message ?? "error"}`));
  });
}

function linesOf(socket) {
  const lines = new w.Lines(socket);
  socket.onmessage = (event) => lines.push(String(event.data));
  socket.onclose = () => lines.end(new Error("closed"));
  return lines;
}

const admin = await paired(webURL, setterCode, "policy998 admin");
const me = { user: "walk" };
const policy = {
  version: 0, issued: 0, changedBy: me, requires: ["host.policy/1"],
  permissionMode: "approveForMe",
  sandbox: "required",
  runtimes: { claude: { models: ["claude-sonnet-*"] }, codex: {} },
  marketplaces: { allowed: [], customServers: "refuse" },
  budgets: { daily: 40, dailyTokens: 50000, allowUnmetered: [], raises: [] },
  helpers: { mostRunning: 2, mostNotArchived: 5 },
  environment: { passThrough: ["AWS_*"] },
};
const kept = await admin.ask("policy/get");
const set = await admin.ask("policy/set", { policy, rev: kept.result?.rev });
console.log("policy/set:", set.error ? `REFUSED ${set.error.message}` : `v${set.result.policy?.version}`);
await sleep(3000);

const host = "mac";
const state = await admin.ask("daemon/policyState", {}, host);
console.log("daemon/policyState:", JSON.stringify({ version: state.result?.version, stopAll: state.result?.stopAll, error: state.error?.message }));
const runtimes = await admin.ask("runtimes/list", {}, host);
console.log("runtimes marked:", (runtimes.result ?? []).filter((r) => r.setBy).map((r) => `${r.runtime.id}: ${r.setBy.words}`));
const sandbox = await admin.ask("sandbox/state", {}, host);
console.log("sandbox setBy:", sandbox.result?.setBy?.words);
const cost = await admin.ask("cost/state", {}, host);
console.log("cost organisation:", JSON.stringify(cost.result?.organisation), "setBy:", cost.result?.setBy?.words);
const names = await admin.ask("settings/passThrough", {}, host);
console.log("pass-through:", (names.result?.names ?? []).map((n) => `${n.name}${n.setBy ? " (refused)" : ""}`));
const options = await admin.ask("agents/options", { runtimeID: "claude", cwd: `file://${folder}`, mcpServers: [] }, host);
const marked = (options.result?.options ?? []).flatMap((o) => (o.options ?? []).flatMap((c) => c.options ?? [c]).filter((c) => c.setBy)
  .map((c) => `${o.id}=${c.name}`));
console.log("options marked:", marked.length ? marked : options.error?.message ?? "none");

const chrome = await launch({ profile: `/tmp/run-p998-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);
  const folder = `#/h/${host}/p/${encodeURIComponent(`file://${folder}`)}/n/1`;
  await page.eval(`location.hash = ${JSON.stringify(folder)}`);
  await sleep(2500);
  await page.shot(`${out}/web-new-agent.png`);
  console.log("runtime options:", await page.eval(`[...document.querySelectorAll('select[aria-label="Runtime"] option')].map((o) => (o.disabled ? "×" : "") + o.textContent).join(" | ")`));
  console.log("sandbox options:", await page.eval(`[...document.querySelectorAll('select[aria-label="Command sandbox"] option')].map((o) => (o.disabled ? "×" : "") + o.textContent).join(" | ")`));
  console.log("mode options:", await page.eval(`[...document.querySelectorAll('.menus select')].map((s) => s.getAttribute("aria-label") + ": " + [...s.options].map((o) => (o.disabled ? "×" : "") + o.textContent).join(" | ")).join(" // ")`));
  await page.eval(`location.hash = "#/a/runtimes"`);
  await sleep(2000);
  await page.shot(`${out}/web-runtimes.png`);
  console.log("runtimes page lines:", await page.eval(`[...document.querySelectorAll(".org-policy-line")].map((e) => e.innerText).length`));
  await page.eval(`location.hash = "#/a/spending"`);
  await sleep(2000);
  await page.shot(`${out}/web-spending.png`);
  console.log("budget:", await page.eval(`document.querySelector(".org-budget")?.innerText ?? "none"`));

  const stop = await admin.ask("policy/stopAll", { on: true });
  console.log("stopAll on:", stop.error?.message ?? "ok");
  await sleep(3000);
  await page.eval(`location.hash = ${JSON.stringify(folder)}`);
  await sleep(2000);
  await page.shot(`${out}/web-stopped.png`);
  console.log("strip:", await page.eval(`document.querySelector(".policy-stopped")?.innerText ?? "none"`));
  console.log("composer:", await page.eval(`document.querySelector('textarea[aria-label="Prompt"]')?.placeholder ?? "none"`));
  // Left on for the window's and the Remote's walk.
} finally {
  await chrome.close();
  admin.close();
}
