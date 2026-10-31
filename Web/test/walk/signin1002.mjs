// The #1002 slice 4 walk: Console ▸ Sign-In on a scratch control plane. Adds a Google Machine provider
// (Save reads Google's public discovery document), presses Check, claims a domain and reads its TXT record,
// turns SCIM on and makes a token (shown once), then marks nothing else. Shoots each step at <out dir>.
//
//   node Web/test/walk/signin1002.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pane = `document.querySelector(".model-access")`;

const chrome = await launch({ profile: `/tmp/run-t9s4-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1100 });
  const fill = async (label, text) => {
    await page.focus(`[aria-label=${JSON.stringify(label)}]`);
    await page.type(text);
  };
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar")`, 20_000);
  await page.eval(`location.hash = "#/console/signIn"`);
  await page.waitFor(`${pane}?.textContent.includes("No providers of your own yet")`, 20_000);
  check(true, "Sign-In opens with the built-in providers and none of the organisation's");
  await page.press("Add Provider…");
  await page.eval(`(() => { const s = document.querySelector('[aria-label="Kind"]'); s.value = "googleWorkspace"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await page.waitFor(`document.querySelector('[aria-label="Issuer"]').value === "https://accounts.google.com"`);
  check(true, "the Google Workspace preset fills the issuer");
  await fill("Name on the button", "Acme Google");
  await fill("Client ID", "walk-client.apps.googleusercontent.com");
  await fill("Client secret", "walk-secret-not-real");
  await page.shot(`${out}/web-signin-add.png`);
  await page.press("Add Provider");
  await page.waitFor(`${pane}?.textContent.includes("Saved Acme Google") || ${pane}?.querySelector("[role=alert]")`, 30_000);
  const saved = (await page.text(".model-access")).replace(/\s+/g, " ");
  console.log(saved.slice(0, 900));
  check(/Saved Acme Google/.test(saved), "the provider is saved");
  check(/Redirect URI .*\/v1\/oidc\/callback/.test(saved), "the card shows the redirect URI to copy");
  check(/Secret [0-9a-f]{8}/.test(saved) && !saved.includes("walk-secret-not-real"), "the secret shows as its fingerprint only");
  await page.press("Check");
  await page.waitFor(`${pane}?.textContent.includes("signing key")`, 30_000);
  check(true, "Check reads the discovery document and the keys");
  await fill("Domain for Acme Google", "walk-acme.example");
  await page.press("Claim Domain");
  await page.waitFor(`${pane}?.textContent.includes("Not proved yet")`, 20_000);
  check((await page.text(".model-access")).includes("TXT record"), "a claimed domain shows its TXT record");
  await page.eval(`(() => { const s = [...document.querySelectorAll(".org-scim input[type=checkbox]")][0]; s.click(); })()`);
  await page.waitFor(`${pane}?.textContent.includes("Base URL")`, 20_000);
  check(true, "Turn On SCIM shows the base URL");
  await fill("Token name for Acme Google", "Walk provisioning");
  await page.press("Make Token");
  await page.waitFor(`${pane}?.textContent.includes("It is not shown again")`, 20_000);
  const token = (await page.text(".org-scim")).replace(/\s+/g, " ");
  check(/agscim_/.test(token), "the token is shown once");
  await page.shot(`${out}/web-signin.png`);
  await page.press("Done");
  await page.waitFor(`!${pane}?.textContent.includes("It is not shown again")`, 10_000);
  check(!(await page.text(".org-scim")).includes("agscim_"), "after Done the value is gone");
  check((await page.text(".org-scim")).includes("not used yet"), "the token's last use is shown");
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) {
    console.log((await page.text("body").catch(() => "")).replace(/\s+/g, " ").slice(0, 2000));
    await page.shot(`${out}/web-signin-failed.png`).catch(() => {});
  }
} finally {
  await chrome.close();
}
console.log(JSON.stringify({ failed }));
process.exit(failed ? 1 : 0);
