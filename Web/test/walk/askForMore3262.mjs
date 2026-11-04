// The #3262 walk: Ask for More. Sets a policy with a budget a day on a scratch control plane as its admin, then
// walks the page in headless Chrome: the Stopped by a policy card of a seeded chat at the organisation's budget,
// Ask for More and the line it leaves, and Console ▸ Requests ▸ Budgets with Raise for Today.
//
//   node Web/test/walk/askForMore3262.mjs <WEB_URL> set <browser code>
//   node Web/test/walk/askForMore3262.mjs <WEB_URL> walk <browser code> <session title> <out dir>
//
// set first, so the window and the Remote can ask too; then walk.

import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const [webURL, phase, code, title, out] = process.argv.slice(2);

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
    async ask(method, params = {}) {
      id += 1;
      socket.send(JSON.stringify({ m: { jsonrpc: "2.0", id, method, params } }));
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

if (phase === "set") {
  const admin = await paired(webURL, code, "ask3262 admin");
  const kept = await admin.ask("policy/get");
  const set = await admin.ask("policy/set", { rev: kept.result?.rev, policy: { version: 0, issued: 0, changedBy: { user: "walk" },
    requires: [], budgets: { daily: 1, allowUnmetered: [], raises: [] } } });
  console.log("policy/set:", set.error ? `REFUSED ${set.error.message}` : `v${set.result.policy?.version}`);
  admin.close();
  process.exit(0);
}

const chrome = await launch({ profile: `/tmp/run-ask3262-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await sleep(6000);
  await page.eval(`location.hash = "#/agents"`);
  await sleep(3000);
  for (const name of ["work", "Sessions"]) {
    await page.eval(`document.querySelector('[aria-label="Unfold ${name}"]')?.click()`);
    await sleep(1200);
  }
  await page.eval(`[...document.querySelectorAll("a,button,[role=button],[role=treeitem],[role=option],li")].reverse().find((e) => e.textContent.includes(${JSON.stringify(title)}))?.click()`);
  await page.waitFor(`document.querySelector(".policy-stop")`, 20_000);
  await sleep(1500);
  await page.shot(`${out}/web-stopped.png`);
  console.log("card:", await page.eval(`document.querySelector(".policy-stop").innerText.replace(/\\n+/g, " / ")`));
  await page.press("Ask for More");
  await page.waitFor(`document.querySelector(".policy-stop").innerText.includes("Asked")`, 20_000);
  await sleep(800);
  await page.shot(`${out}/web-asked.png`);
  await page.eval(`location.hash = "#/requests"`);
  await page.waitFor(`document.getElementById("requests-budgets")`, 20_000);
  await sleep(1500);
  await page.shot(`${out}/web-requests.png`);
  console.log("requests:", await page.eval(`document.getElementById("requests-budgets").parentElement.innerText.replace(/\\n+/g, " / ")`));
  await page.press("Raise for Today");
  await page.waitFor(`!document.getElementById("requests-budgets")`, 20_000);
  await sleep(1500);
  await page.shot(`${out}/web-raised.png`);
} finally {
  await chrome.close();
}
