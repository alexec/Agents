// The #3365 walk: Add as Machine… on a provider's machine, from the web page alone. A commands
// provider stands in for a codespace provider (its ssh destination is the agents-devbox
// container), added over the page's own socket because the page offers only the API kinds. The
// control plane's ssh is given an empty known_hosts (AGENTS_SSH_CONFIG), so the host key is shown
// to trust first. Then it installs, the box joins, and the page links it to its machine.
// Screenshots go to <out dir>.
//
//   node Web/test/walk/addasmachine3365.mjs <WEB_URL> <browser code> <ssh destination> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, destination, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const section = `document.querySelector("[aria-labelledby=settings-providers]")`;
const dialog = `document.querySelector("dialog[open]")`;
const provider = {
  name: "Fake Codespaces", kind: "commands", secrets: {},
  commands: {
    workspaces: [
      { id: "cs-devbox", name: "devbox-codespace", status: "echo running", start: "true", stop: "true", ssh: destination },
      { id: "cs-stopped", name: "stopped-codespace", status: "echo stopped", start: "true", stop: "true", ssh: "agents@127.0.0.1 -p 2299" },
      { id: "cs-nossh", name: "no-ssh-codespace", status: "echo running", start: "true", stop: "true" },
    ],
  },
};

const chrome = await launch({ profile: `/tmp/r3365-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  // Keeps the page's socket, to add the provider the page cannot.
  await page.onNewDocument(`(() => { const W = window.WebSocket; window.WebSocket = function (...a) { const s = new W(...a); window.__walkSocket = s; return s; }; window.WebSocket.prototype = W.prototype; })();`);
  await page.goto(webURL);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.textContent.includes("Settings")`, 20_000);
  await page.eval(`window.__walkSocket.addEventListener("message", (e) => { if (String(e.data).includes("walk-3365")) window.__walkAdded = String(e.data); })`);
  await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify({ jsonrpc: "2.0", id: "walk-3365", method: "providers/add", params: provider }))})`);
  await page.waitFor(`!!window.__walkAdded`, 30_000);
  const added = await page.eval(`window.__walkAdded`);
  check(!added.includes('"error"'), `the fake provider added: ${added.slice(0, 300)}`);

  await page.goto(`${new URL(webURL).origin}/#/settings`);
  await page.waitFor(`${section}?.textContent.includes("devbox-codespace")`, 30_000);
  await page.waitFor(`${section}.textContent.includes("no-ssh-codespace")`, 30_000);
  const buttons = await page.eval(`JSON.stringify([...${section}.querySelectorAll("button")].filter((b) => b.textContent === "Add as Machine…").map((b) => b.disabled))`);
  check(buttons === "[false,true]", `Add as Machine… on the two with ssh, pressable only on the running one: ${buttons}`);
  const listed = (await page.text("[aria-labelledby=settings-providers]")).replace(/\s+/g, " ");
  check(!listed.includes("in the Mac app, in Settings"), "nothing sends the person to the Mac app");
  await page.eval(`${section}.scrollIntoView()`);
  await page.shot(`${out}/web-1-rows.png`);

  await page.press("Add as Machine…");
  await page.waitFor(dialog);
  await page.shot(`${out}/web-2-dialog.png`);
  await page.press("Install");
  await page.waitFor(`${dialog}?.textContent.includes("host key is new")`, 60_000);
  check(true, "the new host key is shown first");
  await page.shot(`${out}/web-3-trust.png`);
  await page.press("Trust and Install");
  await page.waitFor(`${dialog}?.textContent.includes("Installed on") || !!${dialog}?.querySelector(".failure")`, 240_000);
  const said = (await page.text("dialog[open]")).replace(/\s+/g, " ");
  check(said.includes("Installed on devbox-codespace"), `installed: ${said.slice(0, 300)}`);
  await page.shot(`${out}/web-4-installed.png`);
  await page.press("Done");
  await page.waitFor(`${section}.textContent.includes("linked to devbox-codespace")`, 90_000);
  check(true, "linked to its machine once it joined");
  await page.eval(`${section}.scrollIntoView()`);
  await page.shot(`${out}/web-5-linked.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) {
    console.log((await page.text("[aria-labelledby=settings-providers]").catch(() => "")).replace(/\s+/g, " ").slice(0, 1500));
    await page.shot(`${out}/web-failed.png`).catch(() => undefined);
  }
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
