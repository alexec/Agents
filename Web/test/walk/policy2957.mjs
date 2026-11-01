// The #2957 slice 4 walk: Settings ▸ Agents ▸ Policy on the page, alone (frame C), then with a scratch
// organisation policy that caps the permission mode and the day's budget (frame A), and Where this comes from
// open (frame B). Leaves the organisation policy set, for the window's walk.
//
//   node Web/test/walk/policy2957.mjs <WEB_URL> <admin browser code> <page browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const [webURL, setterCode, pageCode, out] = process.argv.slice(2);

/** Pairs as a browser at `base`, then connects again as itself; returns a raw line client (policy998.mjs). */
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

const top = (id) => `document.getElementById(${JSON.stringify(id)})?.scrollIntoView({ block: "start" })`;
const admin = await paired(webURL, setterCode, "policy2957 admin");
const chrome = await launch({ profile: `/tmp/s4-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 1000 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/settings/settings"`);
  await sleep(3000);
  await page.shot(`${out}/debug.png`);
  await page.waitFor(`document.getElementById("settings-agents-policy")`, 20_000);
  await sleep(2000);
  await page.eval(top("settings-scope-app"));
  await sleep(500);
  await page.shot(`${out}/web-this-browser.png`);
  await page.eval(top("settings-scope-agents"));
  await sleep(500);
  await page.shot(`${out}/web-alone.png`);
  console.log("banner:", await page.eval(`document.querySelector(".policy-banner")?.innerText`));

  const policy = { version: 0, issued: 0, changedBy: { user: "walk" }, requires: ["host.policy/1"],
    permissionMode: "approveForMe", budgets: { daily: 25, allowUnmetered: [], raises: [] } };
  const kept = await admin.ask("policy/get");
  const set = await admin.ask("policy/set", { policy, rev: kept.result?.rev });
  console.log("policy/set:", set.error ? `REFUSED ${set.error.message}` : `v${set.result.policy?.version}`);
  await sleep(4000);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.getElementById("settings-agents-policy")`, 20_000);
  await page.waitFor(`document.querySelector(".policy-banner")`, 20_000);
  await sleep(2000);
  await page.eval(top("settings-scope-agents"));
  await sleep(500);
  await page.shot(`${out}/web-org-cap.png`);
  console.log("banner:", await page.eval(`document.querySelector(".policy-banner")?.innerText`));
  console.log("mode options:", await page.eval(`[...document.getElementById("policy-permissionMode").options].map((o) => (o.disabled ? "×" : "") + o.textContent).join(" | ")`));
  await page.eval(`document.querySelector(".policy-rule button.link").click()`);
  await sleep(800);
  await page.shot(`${out}/web-source.png`);
} finally {
  await chrome.close();
  admin.close();
}
