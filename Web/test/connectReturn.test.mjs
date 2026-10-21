// Return in Connect GitLab's Access token and Connect Email connects (#1864): each form's
// Connect is its submit button, and the password field asks for a saved password.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sheet = readFileSync(new URL("../src/views/ConnectorSetup.tsx", import.meta.url), "utf8");

for (const [id, connect] of [["connect-token", "connectWithToken"], ["connect-email", "connectWithEmail"]]) {
  test(`connect sheet: Return in #${id} connects`, () => {
    assert.match(sheet, new RegExp(`<form id="${id}"[^>]*onSubmit=\\{[^}]*${connect}\\(\\)`));
    assert.match(sheet, new RegExp(`<button type="submit" form="${id}"`));
    assert.doesNotMatch(sheet, new RegExp(`onClick=\\{\\(\\) => void ${connect}\\(\\)\\}`), "Connect goes through the form, not a click of its own");
  });
}

test("connect sheet: the email password is a saved password, not a new one", () => {
  assert.doesNotMatch(sheet, /autocomplete="new-password"/);
  assert.match(sheet, /type="password"[^>]*autocomplete="current-password"/);
});
