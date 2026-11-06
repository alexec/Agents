#!/usr/bin/env node
// Signs the Okta walk's test person in (#3415): it opens a sign-in start address from
// TestOktaLive in the sign-up skill's private Chrome, goes through Okta's sign-in (the
// username, the password from the Keychain, and a passkey), and writes the ticket from the
// address the plane sent the browser back to. The passkey lives on Chrome's virtual
// authenticator, for tests, which is gone when this script ends, so its key is kept in a
// file (0600) and put back on the next run; on the first run, Okta asks the person to set
// one up and the script does. Never prints a secret.
//
//   CDP_PORT=9228 node scripts/okta-signin.mjs <start file> <ticket file>
//
//   OKTA_TEST_USER      the person's username at Okta
//   OKTA_PASSWORD_ITEM  their password's Keychain item, service#account
//   OKTA_PASSKEY_FILE   where their passkey's key is kept
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const [startFile, ticketFile] = process.argv.slice(2);
const port = process.env.CDP_PORT ?? "9228";
const user = process.env.OKTA_TEST_USER;
const [service, account] = process.env.OKTA_PASSWORD_ITEM.split("#");
const keyFile = process.env.OKTA_PASSKEY_FILE;
const password = execFileSync("security", ["find-generic-password", "-s", service, "-a", account, "-w"]).toString().trim();

const pages = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).filter((t) => t.type === "page");
const ws = new WebSocket(pages[0].webSocketDebuggerUrl);
await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
let id = 0;
const waiting = new Map();
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
};
const send = (method, params = {}) => new Promise((ok, bad) => {
  const n = ++id;
  waiting.set(n, (msg) => (msg.error ? bad(new Error(`${method}: ${msg.error.message}`)) : ok(msg.result)));
  ws.send(JSON.stringify({ id: n, method, params }));
});
const page = async (js) => (await send("Runtime.evaluate", { expression: js, returnByValue: true, awaitPromise: true })).result.value;
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

await send("WebAuthn.enable", { enableUI: false });
const { authenticatorId } = await send("WebAuthn.addVirtualAuthenticator", { options: {
  protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
  isUserVerified: true, automaticPresenceSimulation: true } });
if (existsSync(keyFile)) {
  await send("WebAuthn.addCredential", { authenticatorId, credential: JSON.parse(readFileSync(keyFile, "utf8")) });
}
await send("Page.navigate", { url: readFileSync(startFile, "utf8").trim() });

// Types into a field with real input, as a person would.
async function fill(selector, text) {
  await page(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); e.focus(); e.select?.(); })()`);
  await send("Input.insertText", { text });
}

// What the page asks for now, by what it shows.
const state = `(() => {
  const shown = (s) => [...document.querySelectorAll(s)].find((e) => e.offsetParent !== null);
  const back = new URLSearchParams(location.hash.slice(1));
  if (back.get("oidc-ticket") || back.get("ticket")) return { ticket: back.get("oidc-ticket") || back.get("ticket") };
  if (back.get("oidc-error") || back.get("error")) return { error: (back.get("oidc-error") || back.get("error")) + ": " + (back.get("oidc-message") || back.get("message")) };
  if (shown("input[name=identifier]") && !shown("input[name=identifier]").value) return { step: "identifier" };
  if (shown("input[name='credentials.passcode']") && !shown("input[name='credentials.passcode']").value) return { step: "password" };
  if (shown("a.webauthn-setup")) return { step: "click", css: "a.webauthn-setup" };
  if (shown("a[aria-label='Set up a passkey.']")) return { step: "click", css: "a[aria-label='Set up a passkey.']" };
  if (shown("a[aria-label='Select a passkey.']")) return { step: "click", css: "a[aria-label='Select a passkey.']" };
  const more = [...document.querySelectorAll("a,input[type=submit]")].find((e) => e.offsetParent !== null && /^(Continue|Skip|Remind me later)$/.test((e.innerText || e.value || "").trim()));
  if (more && /Optional/.test(document.body.innerText)) return { step: "click", el: (more.innerText || more.value).trim() };
  return { step: "wait", text: document.body.innerText.slice(0, 200) };
})()`;

let last = "";
const deadline = Date.now() + 120_000;
let result;
while (Date.now() < deadline) {
  await sleep(1500);
  let now;
  try { now = await page(state); } catch { continue; } // the page is between documents
  if (!now) continue;
  if (now.ticket || now.error) { result = now; break; }
  const step = JSON.stringify(now);
  if (now.step === "wait") {
    if (step !== last) console.log("waiting:", now.text.replace(/\s+/g, " ").slice(0, 120));
  } else {
    console.log("step:", now.step, now.css ?? now.el ?? "");
  }
  last = step;
  if (now.step === "identifier") {
    await fill("input[name=identifier]", user);
    await page(`document.querySelector("input[type=submit]").click()`);
  } else if (now.step === "password") {
    await fill("input[name='credentials.passcode']", password);
    await page(`document.querySelector("input[type=submit]").click()`);
  } else if (now.step === "click" && now.css) {
    await page(`document.querySelector(${JSON.stringify(now.css)}).click()`);
    await sleep(3000);
  } else if (now.step === "click") {
    await page(`[...document.querySelectorAll("a,input[type=submit]")].find((e) => e.offsetParent !== null && (e.innerText || e.value || "").trim() === ${JSON.stringify(now.el)}).click()`);
  }
}

// Keep the passkey for the next run.
const { credentials } = await send("WebAuthn.getCredentials", { authenticatorId });
if (credentials.length > 0) {
  writeFileSync(keyFile, JSON.stringify(credentials[0]), { mode: 0o600 });
}
ws.close();
if (!result) { console.error("okta-signin: no ticket in 2 minutes"); process.exit(1); }
if (result.error) { console.error("okta-signin:", result.error); process.exit(1); }
writeFileSync(ticketFile, result.ticket, { mode: 0o600 });
console.log("okta-signin: the plane sent the browser back with a ticket");
