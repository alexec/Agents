// The #3369 walk: Agents with no Mac, on a real codespace whose own Docker runs the control plane
// (so the codespace reaches it at localhost, and this Mac reaches it through `gh codespace ports
// forward`). One stage a run, in one Chrome profile, so the browser stays paired:
//
//   join:    pair, add the codespaces-api provider (when $WALK_GITHUB_TOKEN gives its token, over
//            the page's socket, so it is in no screenshot), Add as Machine… on the codespace,
//            trust its host key, and wait for the machine to join and be linked.
//   command: remove $WALK_HOST over the page's socket, then Add a Machine ▸ A server's command.
//   link:    Link to Machine… on a codespace whose machine joined with no link.
//   stop:    Stop on the linked codespace's row.
//   signin:  Runtimes: the codespace's Claude says Sign In…; the sheet gives Claude's link.
//   machine: Settings ▸ Machines and the provider's card: what they say about the codespace now.
//
//   node Web/test/walk/nomac3369.mjs <stage> <WEB_URL> <pin> <profile> <out dir> [browser code] [codespace]

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [stage, webURL, pin, profile, out, code, codespace = "w3369-walk"] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const section = `document.querySelector("[aria-labelledby=settings-providers]")`;
const dialog = `document.querySelector("dialog[open]")`;
const chrome = await launch({ profile, args: [`--ignore-certificate-errors-spki-list=${pin.replace(/-/g, "+").replace(/_/g, "/")}=`] });
let page;

try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.onNewDocument(`(() => { const W = window.WebSocket; window.WebSocket = function (...a) { const s = new W(...a); window.__walkSocket = s; return s; }; window.WebSocket.prototype = W.prototype; })();`);
  await page.goto(webURL);
  await sleep(3000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`!document.querySelector("textarea") && document.body.textContent.includes("Settings")`, 30_000);
  check(true, "paired");

  if (stage === "join") {
    await page.waitFor(`window.__walkSocket?.readyState === 1`, 20_000);
    if (process.env.WALK_GITHUB_TOKEN) {
      await page.eval(`window.__walkSocket.addEventListener("message", (e) => { if (String(e.data).includes("walk-3369")) window.__walkAdded = String(e.data); })`);
      const provider = { name: "GitHub Codespaces", kind: "commands", commands: { preset: "codespaces-api", repo: "alexec/agents-walk" }, secrets: { GITHUB_TOKEN: process.env.WALK_GITHUB_TOKEN } };
      await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify({ jsonrpc: "2.0", id: "walk-3369", method: "providers/add", params: provider }))})`);
      await page.waitFor(`!!window.__walkAdded`, 60_000);
      const added = await page.eval(`window.__walkAdded`);
      check(!added.includes('"error"'), `the provider added: ${added.slice(0, 200)}`);
    }

    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`${section}?.textContent.includes(${JSON.stringify(codespace)})`, 60_000);
    await page.eval(`${section}.scrollIntoView()`);
    console.log("card: " + (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ").slice(0, 600));
    await page.shot(`${out}/web-1-card.png`);
    await page.press("Add as Machine…");
    await page.waitFor(dialog);
    await page.shot(`${out}/web-2-dialog.png`);
    await page.press("Install");
    await page.waitFor(`${dialog}?.textContent.includes("host key is new") || ${dialog}?.textContent.includes("Installed on") || !!${dialog}?.querySelector(".failure")`, 120_000);
    console.log("dialog: " + (await page.text("dialog[open]")).replace(/\s+/g, " ").slice(0, 600));
    await page.shot(`${out}/web-3-trust.png`);
    if (await page.eval(`${dialog}.textContent.includes("host key is new")`)) await page.press("Trust and Install");
    await page.waitFor(`${dialog}?.textContent.includes("Installed on") || !!${dialog}?.querySelector(".failure")`, 300_000);
    const said = (await page.text("dialog[open]")).replace(/\s+/g, " ");
    check(said.includes("Installed on"), `installed: ${said.slice(0, 400)}`);
    await page.shot(`${out}/web-4-installed.png`);
    await page.press("Done");
    await page.waitFor(`${section}.textContent.includes("linked to")`, 120_000);
    check(true, "linked to its machine once it joined");
    await page.eval(`${section}.scrollIntoView()`);
    await page.shot(`${out}/web-5-linked.png`);
  } else if (stage === "signin") {
    // With one machine the page lists its runtimes with no section of their own.
    const runtimes = `([...document.querySelectorAll(".runtimes-page section")].find((s) => s.querySelector("h2")?.textContent === ${JSON.stringify(codespace)}) ?? document.querySelector(".runtimes-page"))`;
    const claudeRow = `[...(${runtimes})?.querySelectorAll(".runtime-list li") ?? []].find((li) => li.querySelector(".strong")?.textContent === "Claude")`;
    await page.eval(`location.hash = "#/a/runtimes"`);
    await page.waitFor(`!!(${runtimes})`, 60_000);
    await page.waitFor(`(${claudeRow})?.textContent.includes("Sign In…")`, 60_000).catch(() => undefined);
    console.log("runtimes: " + (await page.eval(`(${runtimes})?.textContent ?? ""`)).replace(/\s+/g, " ").slice(0, 600));
    await page.eval(`(${runtimes}).scrollIntoView()`);
    await page.shot(`${out}/web-6-runtimes.png`);
    await page.eval(`[...(${claudeRow}).querySelectorAll("button")].find((b) => b.textContent === "Sign In…").click()`);
    await page.waitFor(`document.querySelector(".runtime-sign-in .sign-in-link a") || document.querySelector(".runtime-sign-in [role=alert]")`, 90_000);
    const link = await page.eval(`document.querySelector(".runtime-sign-in .sign-in-link a")?.href ?? document.querySelector(".runtime-sign-in [role=alert]").textContent`);
    check(/^https:\/\/claude\.(ai|com)\/.*oauth\/authorize\?/.test(link), `the sheet gives Claude's link: ${link.slice(0, 60)}…`);
    await page.shot(`${out}/web-7-signin.png`);
  } else if (stage === "command") {
    // The machine Add as Machine… joined goes first, over the page's socket: the page has no
    // Remove for a machine. Then Add a Machine ▸ A server gives the command, which this prints.
    await page.waitFor(`window.__walkSocket?.readyState === 1`, 20_000);
    const host = process.env.WALK_HOST;
    if (host) {
      await page.eval(`window.__walkSocket.addEventListener("message", (e) => { if (String(e.data).includes("walk-3369-r")) window.__walkRemoved = String(e.data); })`);
      await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify({ jsonrpc: "2.0", id: "walk-3369-u", method: "hosts/unlink", params: { host } }))})`);
      await sleep(2000);
      await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify({ jsonrpc: "2.0", id: "walk-3369-r", method: "hosts/remove", params: { host } }))})`);
      await page.waitFor(`!!window.__walkRemoved`, 30_000);
      const removed = await page.eval(`window.__walkRemoved`);
      check(!removed.includes('"error"'), `the machine removed: ${removed.slice(0, 200)}`);
    }
    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Add a Machine…")`, 30_000);
    await page.press("Add a Machine…");
    await page.waitFor(dialog);
    await page.eval(`[...document.querySelectorAll("dialog[open] [role=radio]")].find((b) => b.textContent.startsWith("A server")).click()`);
    await page.press("Next");
    await page.waitFor(`!!document.querySelector("dialog[open] code[aria-label=Command]")`, 30_000);
    const command = await page.eval(`document.querySelector("dialog[open] code[aria-label=Command]").textContent`);
    await page.shot(`${out}/web-11-command.png`);
    console.log(`COMMAND ${command}`);
  } else if (stage === "link") {
    // Link to <machine>…: for a machine that joined with no link (the command, or an install
    // the page gave up on).
    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`[...${section}?.querySelectorAll("button") ?? []].some((b) => b.textContent.startsWith("Link to"))`, 60_000);
    console.log("card: " + (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ").slice(0, 600));
    await page.eval(`${section}.scrollIntoView()`);
    await page.shot(`${out}/web-8-unlinked.png`);
    await page.eval(`[...${section}.querySelectorAll("button")].find((b) => b.textContent.startsWith("Link to")).click()`);
    await page.waitFor(dialog);
    await page.shot(`${out}/web-9-link.png`);
    await page.press("Link");
    await page.waitFor(`${section}.textContent.includes("linked to")`, 60_000);
    check(true, "linked to its machine");
    await page.shot(`${out}/web-10-linked.png`);
  } else if (stage === "stop") {
    // Stop on the linked codespace's row (it asks first when agents are running).
    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`[...${section}?.querySelectorAll("button") ?? []].some((b) => b.textContent === "Stop")`, 60_000);
    await page.eval(`window.confirm = () => true`);
    await page.eval(`${section}.scrollIntoView()`);
    await page.shot(`${out}/web-12-before-stop.png`);
    await page.press("Stop");
    await sleep(15_000);
    console.log("card: " + (await page.text("[aria-labelledby=settings-providers]").catch(() => "")).replace(/\s+/g, " ").slice(0, 500));
    await page.shot(`${out}/web-13-stopping.png`);
  } else if (stage === "machine") {
    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`${section}?.textContent.includes(${JSON.stringify(codespace)})`, 60_000);
    await sleep(2000);
    console.log("card: " + (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ").slice(0, 800));
    await page.eval(`${section}.scrollIntoView()`);
    await page.shot(`${out}/web-machine-${Date.now()}.png`);
  }
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) {
    console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
    await page.shot(`${out}/web-failed-${stage}.png`).catch(() => undefined);
  }
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
