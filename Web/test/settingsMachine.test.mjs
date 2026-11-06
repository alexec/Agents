// Settings' per-machine panes on a control plane with no Mac name the machines there are (#3368).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/settingsMachine.ts");
const row = (id, state = "online", extra = {}) => ({ id, name: `${id} box`, platform: "Linux", version: "1", state, reach: "", ...extra });

test("settings machine: with a Mac, the panes are the Mac's alone", () => {
  const hosts = [row("mac", "offline"), row("cs")];
  assert.deepEqual(m.settingsMachines(hosts, "mac").map((h) => h.id), ["mac"]);
  assert.equal(m.settingsMachine(m.settingsMachines(hosts, "mac"), "cs", undefined).id, "mac");
});

test("settings machine: with no Mac, each machine that answers, the chosen one or the home host first", () => {
  const hosts = [row("a"), row("b"), row("down", "offline")];
  const machines = m.settingsMachines(hosts, "mac");
  assert.deepEqual(machines.map((h) => h.id), ["a", "b"]);
  assert.equal(m.settingsMachine(machines, null, "b").id, "b");
  assert.equal(m.settingsMachine(machines, "a", "b").id, "a");
  assert.equal(m.settingsMachine(machines, "gone", undefined).id, "a");
  assert.equal(m.settingsMachine([], null, undefined), undefined);
});

test("settings machine: the words name the machine, not a Mac", () => {
  assert.equal(m.machineOnly("cs box"), "cs box's");
  assert.equal(m.machineKeepsItsOwn("cs box"), "Each machine keeps its own ~/.agents. These files are on cs box only.");
  assert.doesNotMatch(m.noMachineYet, /\bMac\b/);
});
