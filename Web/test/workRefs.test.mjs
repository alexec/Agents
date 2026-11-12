// #4800: a ref in the full form shows the same words and addresses as the old form did.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const work = await load("src/model/work.ts");
const value = await load("src/model/value.ts");
const lead = await load("src/model/leadProgress.ts");

test("work refs: the full form reads as the old form did", () => {
  for (const [full, old] of [
    ["github:issue:alexec/agents#12", "github:alexec/agents#12"], ["gitlab:mr:group/app#4", "gitlab:group/app!4"],
    ["linear:issue:eng#ENG-4", "linear:ENG-4"], ["github:release:alexec/agents#v1.2.0", "github:alexec/agents/release/v1.2.0"],
  ]) {
    assert.equal(work.repoOf(full), work.repoOf(old), full);
    assert.equal(work.shortRef(full), work.shortRef(old), full);
    assert.equal(work.refNumber(full), work.refNumber(old), full);
    assert.equal(work.forgeName(full), work.forgeName(old), full);
    const kind = full.split(":")[1] === "release" ? "release" : full.includes(":mr:") ? "pr" : "issue";
    assert.equal(value.nodeName({ kind, ref: full }), value.nodeName({ kind, ref: old }), full);
    assert.equal(value.nodeUrl({ kind, ref: full }), value.nodeUrl({ kind, ref: old }), full);
  }
  assert.equal(work.repoName("github:repo:#alexec/agents"), "alexec/agents");
});

test("work refs: a lead's epic is found by its session's id, with or without its project", () => {
  const to = { kind: "issue", ref: "github:issue:alexec/agents#7" };
  const links = [{ from: { kind: "session", ref: "agents:session:alexec/agents#A1" }, to, rel: "works-on", source: "start", at: 1 }];
  assert.deepEqual(lead.leadEpic("A1", links), to);
  assert.deepEqual(lead.leadEpic("A1", [{ ...links[0], from: { kind: "session", ref: "session:A1" } }]), to);
});
