// The order runtimes are listed in (#154), the same rule as RuntimeCatalog.sortedByName.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/model/runtimes.ts");
const status = (id, name, available = true) => ({
  runtime: { id, name }, availability: available ? { available: { path: "/x", supportsResume: true } } : { missing: { lookedIn: [] } },
});

test("runtimes: alphabetical by the name shown, not the id or the order sent", () => {
  const sent = [status("claude", "Claude"), status("grok", "Grok"), status("copilot", "Copilot"),
    status("cursor", "Cursor"), status("codex", "Codex"), status("gemini", "Gemini"),
    status("antigravity", "Antigravity"), status("opencode", "OpenCode")];
  assert.deepEqual(r.sortedRuntimes(sent).map((s) => s.runtime.name),
    ["Antigravity", "Claude", "Codex", "Copilot", "Cursor", "Gemini", "Grok", "OpenCode"]);
});

test("runtimes: case does not count, and the id breaks a tie", () => {
  const sent = [status("b", "beta"), status("z", "Alpha"), status("a", "alpha")];
  assert.deepEqual(r.sortedRuntimes(sent).map((s) => s.runtime.id), ["a", "z", "b"]);
});

test("runtimes: a new agent gets the default when it can start, else the first", () => {
  assert.equal(r.firstChoice([status("antigravity", "Antigravity"), status("claude", "Claude")]), "claude");
  assert.equal(r.firstChoice([status("codex", "Codex"), status("gemini", "Gemini")]), "codex");
  assert.equal(r.firstChoice([]), undefined);
});
