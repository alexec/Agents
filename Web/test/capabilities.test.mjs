// Capabilities (#1748): what a host can do, and what the page says about one too old.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const caps = await load("src/model/capabilities.ts");
const generated = await load("src/protocol/capabilities.generated.ts");

const row = (extra) => ({ id: "box", name: "Box", platform: "linux", version: "0.6.0", state: "online", reach: "dialOut", ...extra });

test("a host has what its list names, and everything when it said no list", () => {
  const hosts = [row({ capabilities: [generated.Capability.agents1] }), { ...row(), id: "old" }];
  assert.equal(caps.hostHas(hosts, "box", generated.Capability.agents1), true);
  assert.equal(caps.hostHas(hosts, "box", generated.Capability.chatBranch1), false);
  assert.equal(caps.hostHas(hosts, "old", generated.Capability.chatBranch1), true);
  assert.equal(caps.hostHas(hosts, "elsewhere", generated.Capability.chatBranch1), true);
});

test("a host without the required set says what to update it to", () => {
  const old = row({ state: "needsUpdate", capabilities: ["agents/1"], missing: ["host.wire/1"] });
  assert.equal(caps.stateWords(old), "Needs an update");
  assert.equal(caps.missingWords(old, "0.7.0"), "Update this host to Agents 0.7.0. It does not have host.wire/1.");
  assert.equal(caps.missingWords(row(), "0.7.0"), null);
  assert.equal(caps.versionWords(row({ implementation: "go" })), "Agents 0.6.0 (Go)");
});

test("a host that needs an update still answers; one offline does not (#1771)", () => {
  assert.equal(caps.hostAnswers("online"), true);
  assert.equal(caps.hostAnswers("needsUpdate"), true);
  for (const state of ["offline", "connecting", "failed", "stopped", undefined]) assert.equal(caps.hostAnswers(state), false, state);
});

test("the generated tables name a capability for each method", () => {
  assert.equal(generated.HostCapabilities["agents/branchFrom"], "chat.branch/1");
  assert.deepEqual(generated.DeclaredCapabilities.client, ["client.wire/1"]);
});

test("the page says when it is too old for the control plane", () => {
  assert.equal(caps.appMissingWords({ host: [], client: ["client.wire/1"] }, "0.7.0"), null);
  assert.equal(caps.appMissingWords({ host: [], client: ["client.wire/2"] }, "0.8.0"),
    "Update this page to Agents 0.8.0 to use this control plane. It does not have client.wire/2.");
  assert.equal(caps.appMissingWords(undefined, "0.6.0"), null);
});
