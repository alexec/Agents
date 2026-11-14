// A machine page's Agent Loops section (#5273): the words, as AgentsKit's AgentsVersionWordsTests say them for the Mac and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/agentsVersions.ts");
const dates = await load("src/protocol/dates.ts");
const at = (y, mo, d, h, mi) => dates.toWireDate(new Date(y, mo, d, h, mi));
const changes = { base: "0.18.0", head: "0.18.1-dev.544+g8162a5a06", ahead: 544, behind: 0, changes: [], complete: false };

test("the version and its build", () => {
  assert.deepEqual(m.versionParts("0.18.1-dev.544+g8162a5a06"), { name: "0.18.1-dev.544", build: "+g8162a5a06" });
  assert.deepEqual(m.versionParts("0.18.0"), { name: "0.18.0", build: null });
});

test("since when, and the changes since the version before", () => {
  const agents = { host: "mac", version: "0.18.1-dev.544+g8162a5a06", since: at(2026, 10, 13, 15, 22), previous: "0.18.0", changes, history: [], others: [] };
  assert.equal(m.sinceLine(agents), "since 13 Nov, 15:22 · 544 changes since 0.18.0, the version before");
  assert.equal(m.sinceLine({ ...agents, changes: undefined }), "since 13 Nov, 15:22 · the version before was 0.18.0; its changes can’t be read now");
  assert.equal(m.sinceLine({ ...agents, previous: undefined, changes: undefined }), "since 13 Nov, 15:22");
  assert.equal(m.listHeading(changes), "544 changes since 0.18.0 · newest first");
  assert.equal(m.showAllWords(changes), "Show all 544");
  assert.equal(m.showAllWords({ ...changes, complete: true }), null);
  assert.equal(m.changeCount(1), "1 change");
});

test("the other machines", () => {
  const other = { host: "box", name: "linux-server", version: "0.18.0", since: at(2026, 10, 8, 11, 2), ahead: 0, behind: 544 };
  assert.equal(m.otherLine(other), "0.18.0 · since 8 Nov, 11:02");
  assert.equal(m.behindLine(other), "544 changes behind this one");
  assert.ok(m.isBehind(other));
  assert.deepEqual(m.compareWith(other, "0.18.1-dev.544+g8162a5a06"), { base: "0.18.0", head: "0.18.1-dev.544+g8162a5a06" });
  assert.equal(m.behindLine({ ...other, ahead: 3, behind: 0 }), "3 changes ahead of this one");
  assert.equal(m.behindLine({ ...other, ahead: 3, behind: 5 }), "3 ahead of and 5 behind this one");
  assert.equal(m.behindLine({ ...other, ahead: 0, behind: 0 }), null);
  assert.equal(m.behindLine({ ...other, ahead: undefined, behind: undefined }), null);
});

test("a change's link and label", () => {
  assert.equal(m.changeLink({ number: 5250, title: "t", sha: "abc" }), "https://github.com/agentloops-dev/agent-loops/pull/5250");
  assert.equal(m.changeLabel({ title: "t", sha: "8162a5a06123" }), "8162a5a");
});
