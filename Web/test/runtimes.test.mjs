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

for (const { name, input, expected } of (await import("./fixtures.mjs")).cases("runtimes/reasons.json")) {
  test(`runtimes: why it cannot start, ${name}`, () => assert.equal(r.unavailableReason(input), expected));
}

test("runtimes: a chooser's runs are available, out and cannot start", () => {
  const out = { ...status("grok", "Grok"), isOut: true };
  const got = r.runtimeRuns([status("claude", "Claude"), out, status("codex", "Codex", false)]);
  assert.deepEqual([got.available, got.out, got.cannot].map((run) => run.map((s) => s.runtime.id)), [["claude"], ["grok"], ["codex"]]);
});

for (const { name, input, expected } of (await import("./fixtures.mjs")).cases("runtimes/new-session.json")) {
  test(`runtimes: a new session opens on, ${name}`, () => assert.equal(r.newSessionRuntime(input.kept ?? undefined, input.available) ?? null, expected));
}

test("runtimes: an empty list says so when nothing on this Mac can start (#257)", () => {
  assert.equal(r.noAgentRuntime(undefined), false, "not yet listed is not none");
  assert.equal(r.noAgentRuntime([]), true);
  assert.equal(r.noAgentRuntime([status("claude", "Claude", false)]), true);
  assert.equal(r.noAgentRuntime([status("claude", "Claude"), status("codex", "Codex", false)]), false, "one that can start is enough");
  const missing = status("goose", "Goose", false);
  missing.runtime.installPage = "https://example.com/goose";
  assert.deepEqual(r.emptyListRuntimeLine(missing), { line: "Not on this Mac", failed: false, page: "https://example.com/goose" });
  missing.runtime.install = { toolset: { runtimeID: "goose" } };
  assert.deepEqual(r.emptyListRuntimeLine(missing), { line: "Not on this Mac", failed: false }, "Install stays on the Mac");
  const failed = { ...status("codex", "Codex", false), availability: { installFailed: { reason: "disk full" } }, runtime: { ...status("codex", "Codex").runtime, installPage: "https://example.com/codex", install: { toolset: { runtimeID: "codex" } } } };
  assert.deepEqual(r.emptyListRuntimeLine(failed), { line: "disk full", failed: true, page: "https://example.com/codex" });
  const signing = { ...status("claude", "Claude", false), availability: { needsSignIn: { authMethods: [] } } };
  assert.equal(r.emptyListRuntimeLine(signing).line, "Signed out.");
  const installing = { ...status("gemini", "Gemini", false), availability: { installing: { progress: "Fetching" } } };
  assert.deepEqual(r.emptyListRuntimeLine(installing), { line: "Fetching…", failed: false });
});

test("runtimes: a new session stays on the runtime it opened with (#291)", () => {
  assert.equal(r.formRuntime("codex", undefined, ["claude", "codex"], "claude"), "codex", "a later listing does not move it");
  assert.equal(r.formRuntime("codex", "claude", ["claude", "codex"], "codex"), "claude", "a pick here wins");
  assert.equal(r.formRuntime("codex", undefined, ["claude"], "claude"), "claude", "one that can no longer start falls through");
  assert.equal(r.formRuntime(undefined, undefined, ["codex"], undefined), "codex");
  assert.equal(r.formRuntime(undefined, undefined, ["codex", "claude"], undefined), "claude");
});
