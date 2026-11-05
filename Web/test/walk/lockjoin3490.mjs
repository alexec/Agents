// The #3490 walk: a new browser joins the person's machine lock by approval on a device that is in it.
// The window made the root when it paired. The page pairs, asks to join, and shows "Approve this device…";
// the window presses Compare Digits, and both show the same six digits; the window approves; the page is
// then in the lock, and a turn runs from it. It pauses at "MAC" lines for the window's shots and presses,
// until the file <out>/go-on exists. A script client reads the lock and the digits on the way.
//
//   node Web/test/walk/lockjoin3490.mjs <WEB_URL> <browser code> <browser code> <folder name> <out dir>

import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const lock = await load("src/wire/machineLock.ts");
const [webURL, scriptCode, pageCode, folder, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

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
    keys.record = { privateKey: pair.privateKey, publicKey: pair.publicKey, client, control: w.base64url(code.controlKey), paired: "" };
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

/** Takes a shot with this Mac's own name in the page's words given a scratch one: the repo is public. */
async function shot(page, path) {
  await page.eval(`(() => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      n.nodeValue = n.nodeValue.replace(/[A-Z][a-z]+[’']?s[ -]MacBook[ -]Air(\\.local)?/g, "Sam’s MacBook");
    }
  })()`);
  await page.shot(path);
}

async function waitMac(line) {
  console.log(`MAC ${line}`);
  while (!existsSync(`${out}/go-on`)) await sleep(500);
  unlinkSync(`${out}/go-on`);
}

/** The lock as the control plane keeps it, checked here. */
async function readLock(script) {
  const got = (await script.ask("lock/get")).result;
  return { lock: got, state: await lock.check(got.entries) };
}

const script = await paired(webURL, scriptCode, "Walk script");
const chrome = await launch({ profile: `/tmp/run-lock3490-chrome-${process.pid}` });
try {
  let { state } = await readLock(script);
  check(state.count === 1, `the window made the root when it paired: ${state.count} entry`);

  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  // The cards are in the Agents page's sidebar, beside the sign-in cards.
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
  await sleep(800);
  await shot(page, `${out}/web-asking.png`);
  const asked = (await script.ask("lock/joinRequests")).result;
  check(asked.length === 1 && asked[0].kind === "browser", `one browser asks to join: ${JSON.stringify(asked.map((r) => r.name))}`);

  await waitMac("the window shows the browser's card: take mac-request, press Compare Digits, then go on");
  await page.waitFor(`document.body.innerText.includes("Check that the other device shows")`, 30_000);
  await sleep(500);
  await shot(page, `${out}/web-digits.png`);
  const shown = await page.eval(`document.querySelector(".lock-join-own code")?.innerText`);
  writeFileSync(`${out}/digits.txt`, `${shown}\n`);
  console.log(`DIGITS ${shown}`);
  await waitMac(`the window shows the digits: check they are ${shown}, take mac-digits, press Approve, then go on`);

  await page.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
  ({ state } = await readLock(script));
  check(state.count === 2, `the window put the browser's addClient on the lock: ${state.count} entries`);
  const added = state.membersOf("addClient").find((m) => m.clientKind === "web");
  check(!!added, "the lock names the browser as a client");
  await shot(page, `${out}/web-member.png`);

  // A turn from the browser, now in the lock.
  await page.eval(`(() => {
    const b = [...document.querySelectorAll(".sidebar .row.folder .pick")].find((e) => e.innerText.startsWith(${JSON.stringify(folder)}));
    const box = b.getBoundingClientRect();
    b.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 10 }));
  })()`);
  await sleep(300);
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "New Session").click()`);
  await page.waitFor(`document.querySelector(".chat textarea, textarea")`, 15_000);
  await page.focus(".chat textarea, textarea");
  await page.type("Reply with the one word done, and nothing else.");
  await page.key("Enter");
  // The prompt says "done" in the title, the path and its bubble: the answer is a fourth.
  await page.waitFor(`(document.querySelector("main, .chat")?.innerText.match(/\\bdone\\b/gi) ?? []).length >= 4
    && !document.body.innerText.includes("Starting Claude")`, 180_000);
  await sleep(1000);
  await shot(page, `${out}/web-turn.png`);
  check(true, "a turn ran from the browser");
  const errors = (page.errors ?? []).filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `no errors on the page: ${JSON.stringify(errors)}`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.stack ?? e}`);
} finally {
  await chrome.close();
  script.close();
}
process.exit(failed ? 1 : 0);
