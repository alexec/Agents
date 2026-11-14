// New Machine in one step (#5204): the sign-in New Machine asked for opens by itself once the machine joins and its
// runtime is installed. The same cases as the Swift MachineSetupTests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/machineSetup.ts");

const claude = { id: "claude", name: "Claude", executable: "claude", arguments: [] };
const status = (availability, signIn = { signedIn: false }) => ({ runtime: claude, availability, ...(signIn ? { signIn } : {}) });
const available = { available: { path: "/usr/bin/claude", supportsResume: true } };

test("it waits while the runtime is not there yet", () => {
  assert.deepEqual(m.setupStep("claude", undefined, true), { wait: true });
  assert.deepEqual(m.setupStep("claude", [], true), { wait: true });
  assert.deepEqual(m.setupStep("claude", [status({ installing: {} })], true), { wait: true });
  assert.deepEqual(m.setupStep("claude", [status({ missing: { lookedIn: [] } })], true), { wait: true });
});

test("it opens the sign-in when the runtime is not signed in", () => {
  const s = status(available);
  assert.deepEqual(m.setupStep("claude", [s], true), { signIn: s });
});

test("it opens nothing when there is nothing to sign in", () => {
  assert.deepEqual(m.setupStep("claude", [status(available, { signedIn: true })], true), { done: true });
  assert.deepEqual(m.setupStep("claude", [status(available, { signedIn: false, relayed: true })], true), { done: true });
  assert.deepEqual(m.setupStep("claude", [status(available)], false), { done: true });
  assert.deepEqual(m.setupStep("claude", [status(available, null)], true), { done: true });
  assert.deepEqual(m.setupStep("claude", [status({ installFailed: { reason: "no" } })], true), { done: true });
});

test("it keeps the machines until they are done or the wait is over", () => {
  const setups = new m.MachineSetups();
  setups.made("machine-3", "claude", 1000);
  setups.made("machine-4", null, 1000);
  assert.deepEqual(setups.joined(["machine-3", "machine-4", "devbox"], 1000), [{ name: "machine-3", runtimeID: "claude" }]);
  assert.deepEqual(setups.joined(["machine-3"], 1000 + m.setupWait), []);
  setups.made("machine-5", "codex", 1000);
  setups.done("machine-5");
  assert.deepEqual(setups.joined(["machine-5"], 1000), []);
});
