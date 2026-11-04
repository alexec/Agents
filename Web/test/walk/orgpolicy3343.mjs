// The #3343 walk: the organisation's new rules (#2957 FR-003) on Settings ▸ Organisation Policy on the page.
// Pairs as the control plane's admin, shoots the form as it is, sets each new rule, shoots What Changes,
// saves, and shoots the saved form. Screenshots go to <out dir>.
//
//   node Web/test/walk/orgpolicy3343.mjs <WEB_URL> <browser code> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const form = `document.querySelector("form.org-policy")`;
const section = (id) => `document.querySelector("[aria-labelledby=${id}]")`;

/** Sets the control named `label` as a person would: a select's value, a field's text or a switch. */
const set = (label, value) => `(() => {
  const el = document.querySelector(${JSON.stringify(`[aria-label="${label}"]`)})
    ?? [...document.querySelectorAll("form.org-policy label.setting")].find((l) => l.querySelector("span")?.textContent === ${JSON.stringify(label)})
      ?.querySelector("select, input");
  if (!el) return false;
  if (el.type === "checkbox") { if (el.checked !== ${JSON.stringify(value)}) el.click(); return true; }
  el.value = ${JSON.stringify(value)};
  el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
  return true;
})()`;

const chrome = await launch({ profile: `/tmp/run-p3343-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1300, height: 1500 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.textContent.includes("Settings")`, 20_000);
  await page.eval(`location.hash = "#/settings/policy"`);
  await page.waitFor(`${section("org-policy-notices")}`, 20_000);
  await page.eval(`${section("org-policy-modes")}.scrollIntoView()`);
  await page.shot(`${out}/web-empty-top.png`);
  await page.eval(`${section("org-policy-helpers")}.scrollIntoView()`);
  await page.shot(`${out}/web-empty-rules.png`);

  for (const [label, value] of [["Permission requests", "default"], ["Workflows turned on", "5"], ["Notices in a burst", "2"],
    ["Wait after a burst", "60"], ["Agents may archive a person’s chats", false]]) {
    check(await page.eval(set(label, value)), `set ${label}`);
  }
  await page.waitFor(`${section("org-policy-preview")}`);
  const preview = await page.text("[aria-labelledby=org-policy-preview]");
  for (const line of ["Permission requests: Ask me", "Workflows: At most 5 turned on in a folder",
    "Notices: At most 2 in a burst, then a wait of 1 hour", "Archiving chats: Agents may not archive a person’s chats"]) {
    check(preview.includes(line), `What Changes says ${line}`);
  }
  await page.eval(`${section("org-policy-helpers")}.scrollIntoView()`);
  await page.shot(`${out}/web-edited.png`);

  await page.press("Save");
  await page.waitFor(`document.body.textContent.includes("Saved. Every machine has it within seconds.")`, 20_000);
  check(true, "saved");
  // Read again from the control plane: the page loads the form from policy/get.
  await page.eval(`location.hash = "#/settings"`);
  await page.eval(`location.hash = "#/settings/policy"`);
  await page.waitFor(`${section("org-policy-notices")}`, 20_000);
  check(await page.eval(`${form}.querySelector("[aria-label='Workflows turned on']").value === "5"`), "the saved workflows rule reads back");
  check(await page.eval(`${form}.querySelector("[aria-label='Wait after a burst']").value === "60"`), "the saved wait reads back");
  await page.eval(`${section("org-policy-helpers")}.scrollIntoView()`);
  await page.shot(`${out}/web-saved.png`);
} finally {
  await chrome.close();
}
process.exit(failed ? 1 : 0);
