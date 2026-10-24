// The #999 slice 3 walk (quickstart step 3): an org route on a scratch control plane, as its admin,
// a gateway with no key to a fake address; then the page in headless Chrome: Activity ▸ Runtimes
// (the org account's row, From your organisation, Organisation · No plan limit, Reaches the Model
// By), the new-session form's Account choices, and the Continue in New strip over a session whose
// org account is gone. Then the policy's reach of the org path only: the own sign-in dimmed, and the
// strip over a session on it. Leaves the route and the policy set, for the window's and the Remote's walk.
//
//   node Web/test/walk/accounts999.mjs <WEB_URL> <browser code> <browser code> <folder> <gone agent> <own agent> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { load } from "../load.mjs";
import { launch } from "./cdp.mjs";

const w = await load("test/wire.ts");
const [webURL, setterCode, pageCode, folder, goneAgent, ownAgent, out] = process.argv.slice(2);
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

const admin = await paired(webURL, setterCode, "accounts999 admin");
const host = "mac";
const route = { id: "", name: "Fake Gateway", kind: "baseURL", vendor: "anthropic", runtimes: ["claude"],
  settings: { address: "http://127.0.0.1:9" }, groups: [], defaultFor: ["claude"] };
const set = await admin.ask("orgRoutes/set", { route });
check(!set.error, `orgRoutes/set: ${set.error ? set.error.message : set.result.route.id}`);
let profiles = [];
for (let i = 0; i < 20 && !profiles.some((p) => p.source === "organisation"); i++) {
  await sleep(500);
  profiles = (await admin.ask("runtimes/accountProfiles", {}, host)).result ?? [];
}
const org = profiles.find((p) => p.source === "organisation");
check(org?.id === "org:fake-gateway" && org?.isDefault === true, `the machine lists it: ${JSON.stringify(org)}`);
check(!JSON.stringify(profiles).includes("127.0.0.1:9"), "no address reaches a client (FR-026)");
const rows = (await admin.ask("runtimes/allowances", null, host)).result?.rows ?? [];
console.log("its allowance row:", JSON.stringify(rows.find((r) => r.accountID === "org:fake-gateway")));

const chrome = await launch({ profile: `/tmp/run-a999-chrome-${process.pid}` });
const text = (selector) => `[...document.querySelectorAll(${JSON.stringify(selector)})].map((e) => e.innerText)`;
try {
  const page = await chrome.page(webURL, { width: 1280, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(pageCode);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.folder")`, 20_000);

  await page.eval(`location.hash = "#/a/runtimes"`);
  await page.waitFor(`[...document.querySelectorAll(".runtime-list li .strong")].some((s) => s.textContent === "Claude · Fake Gateway")`, 15_000);
  const lines = await page.eval(text(".runtime-list li"));
  const orgLine = lines.find((l) => l.startsWith("Claude · Fake Gateway")) ?? "";
  check(orgLine.includes("Organisation · No plan limit") && orgLine.includes("From your organisation"), `its row: ${JSON.stringify(orgLine)}`);
  const reaches = await page.eval(`(() => { const s = document.querySelector(".reaches-by select"); return s && [...s.options].map((o) => (o.selected ? "✓" : "") + (o.disabled ? "×" : "") + o.textContent); })()`);
  check(JSON.stringify(reaches) === JSON.stringify(["Your Own Sign-In", "✓Fake Gateway"]), `Reaches the Model By: ${JSON.stringify(reaches)}`);
  await page.shot(`${out}/web-1-runtimes.png`);

  const folder = `#/h/${host}/p/${encodeURIComponent(`file://${folder}`)}/n/1`;
  await page.eval(`location.hash = ${JSON.stringify(folder)}`);
  await page.waitFor(`document.querySelector("select[aria-label=Runtime]")`, 15_000);
  await page.eval(`(() => { const s = document.querySelector("select[aria-label=Runtime]"); s.value = "claude"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelector("select[aria-label=Account]")`, 10_000);
  const choices = await page.eval(`[...document.querySelector("select[aria-label=Account]").options].map((o) => (o.selected ? "✓" : "") + o.textContent)`);
  check(JSON.stringify(choices) === JSON.stringify(["Your Own Sign-In", "✓Fake Gateway (from your organisation)"]), `the Account choices: ${JSON.stringify(choices)}`);
  await page.shot(`${out}/web-2-new-session.png`);

  const open = async (id) => {
    await page.eval(`location.hash = ${JSON.stringify(`#/h/${host}/p/${encodeURIComponent(`file://${folder}`)}/s/${id}`)}`);
    await sleep(2500);
    return page.eval(`document.querySelector(".missing-folder-strip")?.innerText ?? "none"`);
  };
  const gone = await open(goneAgent);
  check(gone.includes("Your organisation removed this way to the model.") && gone.includes("Continue in New"), `a session whose account is gone: ${JSON.stringify(gone)}`);
  await page.shot(`${out}/web-3-account-gone.png`);
  check((await open(ownAgent)) === "none", "a session on the own sign-in has no strip while the policy allows it");

  // The org path only: the own sign-in dimmed, and a session on it told to move.
  const kept = await admin.ask("policy/get");
  const policy = { version: 0, issued: 0, changedBy: { user: "walk" }, requires: ["host.policy/1", "host.org-routes/1"],
    runtimes: { claude: { reach: ["orgKey", "gateway"] }, codex: {}, gemini: {}, opencode: {}, antigravity: {}, copilot: {}, cursor: {}, grok: {} } };
  const p = await admin.ask("policy/set", { policy, rev: kept.result?.rev });
  check(!p.error, `policy/set: ${p.error ? p.error.message : `v${p.result.policy?.version}`}`);
  await sleep(4000);
  const own = await open(ownAgent);
  check(own.includes("Your organisation requires Claude to use Fake Gateway.") && own.includes("Continue in New"), `a session on the own sign-in: ${JSON.stringify(own)}`);
  await page.shot(`${out}/web-4-own-refused.png`);
  await page.eval(`location.hash = "#/a/runtimes"`);
  await sleep(2500);
  const refused = await page.eval(`(() => { const s = document.querySelector(".reaches-by select"); return s && [...s.options].map((o) => (o.selected ? "✓" : "") + (o.disabled ? "×" : "") + o.textContent); })()`);
  check(refused?.[0] === "×Your Own Sign-In (Set by your organisation)", `Reaches the Model By under the policy: ${JSON.stringify(refused)}`);
  await page.shot(`${out}/web-5-runtimes-policy.png`);
  // Chrome says this of a page with a focused field; it is not the page's error.
  const errors = (page.errors ?? []).filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `no errors on the page: ${JSON.stringify(errors)}`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.stack ?? e}`);
} finally {
  await chrome.close();
  admin.close();
}
process.exit(failed ? 1 : 0);
