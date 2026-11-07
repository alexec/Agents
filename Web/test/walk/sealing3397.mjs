// The #3397 walk: client sealing on a scratch control plane, the page in headless Chrome as the admin.
// 1. Console ▸ Model Access: Add Route… with a key; the page seals it to the machine and the admins' apps, the
//    machine lists the org account, and no file of the control plane holds the key. Check runs on the machine.
// 2. A route a test client sealed to itself only: the machine waits; Model Access and Settings ▸ Policy say so.
//    The test client then seals it for the machine as an admin's app does on control/sealingWanted.
// 3. Settings ▸ Secrets: Add a Secret…, sealed by the page to the person's machine and apps.
// It pauses at "MAC" lines for the window's shots, until the file <out>/go-on exists.
//
//   node Web/test/walk/sealing3397.mjs <WEB_URL> <browser code> <browser code> <control home> <out dir>

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const s = await load("src/wire/sealing.ts");
const [webURL, setterCode, pageCode, controlHome, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const key = "sk-ant-walk-3397-0000";
const gatewayKey = "gw-walk-3397-1111";
const secret = "ghp_walk3397";

/** Pairs as a browser at `base`, then connects again as itself; returns a raw line client and its key. */
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
    record: keys.record,
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

/** Whether any file under dir holds text. */
function holds(dir, text) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory() ? holds(path, text) : st.size < 50 << 20 && readFileSync(path).includes(text)) return true;
  }
  return false;
}

async function waitMac(line) {
  console.log(`MAC ${line}`);
  while (!existsSync(`${out}/go-on`)) await sleep(500);
  const { unlinkSync } = await import("node:fs");
  unlinkSync(`${out}/go-on`);
}

const setter = await paired(webURL, setterCode, "Walk admin script");
const host = "mac";
const chrome = await launch({ profile: `/tmp/run-seal3397-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.innerText.includes("Settings")`, 30_000);
  await sleep(1500);

  // 1. Add Route… with a key.
  await page.eval(`location.hash = "#/settings/modelAccess"`);
  await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add Route…")`, 15_000);
  await page.press("Add Route…");
  await page.waitFor(`document.querySelector("input[aria-label=Name]")`);
  await page.focus("input[aria-label=Name]");
  await page.type("Acme Anthropic");
  await page.focus("input[aria-label='API key']");
  await page.type(key);
  await page.shot(`${out}/web-add-route.png`);
  await page.eval(`document.querySelector("form.org-policy").requestSubmit()`);
  await page.waitFor(`document.querySelector(".console-table")`, 15_000);
  await sleep(2500);
  await page.shot(`${out}/web-model-access.png`);
  let profiles = [];
  for (let i = 0; i < 30 && !profiles.some((p) => p.id === "org:acme-anthropic"); i++) {
    await sleep(500);
    profiles = (await setter.ask("runtimes/accountProfiles", {}, host)).result ?? [];
  }
  check(profiles.some((p) => p.id === "org:acme-anthropic"), "the machine opened the key the page sealed, and lists the org account");
  check(!holds(controlHome, key), "no file of the control plane holds the key");
  await page.press("Check");
  await page.waitFor(`document.querySelector("[role=status]")?.innerText.includes("Acme Anthropic:")`, 40_000);
  const checked = await page.eval(`document.querySelector("[role=status]").innerText`);
  // Its words name the machine, which is this Mac's own name on a scratch host: no shot.
  check(checked.includes(", checked on "), "Check ran on a machine");

  // 2. A route sealed to the test client only: the machine waits.
  const route = { id: "platform-gateway", name: "Platform Gateway", kind: "baseURL", vendor: "openai", runtimes: ["codex"],
    settings: { address: "https://llm.example.com" }, groups: [], defaultFor: [] };
  const me = s.clientRecipient(setter.record.client);
  const { recipients } = (await setter.ask("orgRoutes/recipients", { groups: [] })).result;
  const values = await s.sealRoute(route, { apiKey: gatewayKey }, 1, recipients.filter((r) => r.id === me));
  const set = await setter.ask("orgRoutes/set", { route, sealed: { sealVersion: 1, fingerprint: { apiKey: await s.fingerprint(gatewayKey) }, values } });
  check(!set.error, `a route sealed to the script only: ${set.error?.message ?? set.result.route.id}`);
  await page.eval(`location.hash = "#/settings/modelAccess"`);
  await page.waitFor(`document.body.innerText.includes("1 waiting")`, 15_000);
  await page.shot(`${out}/web-model-access-waiting.png`);
  await page.eval(`location.hash = "#/settings"`);
  await page.waitFor(`document.body.innerText.includes("Waiting for an admin’s app to seal it")`, 15_000);
  await page.eval(`document.getElementById("settings-policy").scrollIntoView()`);
  await sleep(500);
  await page.shot(`${out}/web-policy-waiting.png`);
  await waitMac("the window: Settings ▸ Organisation Policy, with Platform Gateway waiting");

  // The script seals it for the machine, as an admin's app does on control/sealingWanted.
  const work = (await setter.ask("sealing/work")).result;
  const items = await s.sealWork(setter.record, work);
  check(items.some((i) => i.id === "platform-gateway"), `sealing/work names the waiting route: ${items.map((i) => i.id)}`);
  await setter.ask("sealing/add", { items });
  for (let i = 0; i < 30 && !profiles.some((p) => p.id === "org:platform-gateway"); i++) {
    await sleep(500);
    profiles = (await setter.ask("runtimes/accountProfiles", {}, host)).result ?? [];
  }
  check(profiles.some((p) => p.id === "org:platform-gateway"), "the machine has it once sealed for it");
  await page.eval(`location.hash = "#/settings/modelAccess"`);
  await page.waitFor(`!document.body.innerText.includes("1 waiting") && document.body.innerText.includes("Platform Gateway")`, 15_000);
  await page.shot(`${out}/web-model-access-sealed.png`);

  // 3. A person's secret.
  await page.eval(`location.hash = "#/setup/secrets"`);
  await sleep(1000);
  await page.eval(`document.getElementById("settings-secrets").scrollIntoView()`);
  await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add a Secret…")`, 15_000);
  await page.press("Add a Secret…");
  await page.waitFor(`document.querySelector("input[aria-label=Value]")`);
  await page.focus("input[aria-label=Name]");
  await page.type("GITHUB_TOKEN");
  await page.focus("input[aria-label=Value]");
  await page.type(secret);
  await page.shot(`${out}/web-add-secret.png`);
  await page.eval(`document.querySelector("form.sheet-body").requestSubmit()`);
  await page.waitFor(`document.querySelector("code")?.innerText === "GITHUB_TOKEN"`, 20_000);
  // Which machines have it is noted once each is sent it, with no notice: read it again.
  await sleep(3000);
  await page.eval(`location.reload()`);
  await page.waitFor(`document.body.innerText.includes("On 1 machine")`, 20_000);
  await page.eval(`document.getElementById("settings-secrets").scrollIntoView()`);
  await sleep(500);
  await page.shot(`${out}/web-secrets.png`);
  check(!holds(controlHome, secret), "no file of the control plane holds the secret");
  await waitMac("the window: Settings ▸ Secrets");
  const errors = (page.errors ?? []).filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `no errors on the page: ${JSON.stringify(errors)}`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.stack ?? e}`);
} finally {
  await chrome.close();
  setter.close();
}
process.exit(failed ? 1 : 0);
