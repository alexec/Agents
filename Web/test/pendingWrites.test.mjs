import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const pending = await load("src/model/pendingWrites.ts");

const agent = (over = {}) => ({ id: "A", runtimeID: "claude", cwd: "file:///tmp/work/", title: "Something",
  state: "finished", lastActivityAt: 1, labels: [], ...over });

test("archive shows at once and stays until the host says so (#4786)", () => {
  const writes = new pending.PendingWrites();
  const held = agent();
  const begun = writes.begin("mac", held, { kind: "archive" });
  assert.equal(begun.agent.state, "archived");
  // The copy on screen passes as it is; a host record that has not done it yet keeps it drawn.
  assert.equal(writes.overlay("mac", begun.agent), begun.agent);
  assert.equal(writes.overlay("mac", agent()).state, "archived");
  // Answered: drawn until the host next speaks.
  assert.equal(writes.settle("mac", "A", begun.id, false), null);
  assert.ok(writes.has("mac", "A"));
  assert.equal(writes.overlay("mac", agent({ state: "archived" })).state, "archived");
  assert.ok(!writes.has("mac", "A"));
});

test("a failed call puts the host's newest record back (#4786)", () => {
  const writes = new pending.PendingWrites();
  const begun = writes.begin("mac", agent(), { kind: "mute", muted: true });
  assert.equal(begun.agent.isMuted, true);
  const drawn = writes.overlay("mac", agent({ title: "Renamed elsewhere" }));
  assert.equal(drawn.isMuted, true);
  assert.equal(drawn.title, "Renamed elsewhere");
  const back = writes.settle("mac", "A", begun.id, true);
  assert.equal(back.isMuted, undefined);
  assert.equal(back.title, "Renamed elsewhere");
  assert.ok(!writes.has("mac", "A"));
});

test("one failure leaves the other change drawn (#4786)", () => {
  const writes = new pending.PendingWrites();
  const mute = writes.begin("mac", agent(), { kind: "mute", muted: true });
  writes.begin("mac", mute.agent, { kind: "labels", add: ["bug"], remove: [] });
  const back = writes.settle("mac", "A", mute.id, true);
  assert.equal(back.isMuted, undefined);
  assert.deepEqual(back.labels.map((l) => l.value), ["bug"]);
});

test("unarchive goes back to how it ended, as the host does (#4786)", () => {
  assert.equal(pending.applyWrite(agent({ state: "archived", endedReason: "endTurn" }), { kind: "unarchive" }).state, "finished");
  assert.equal(pending.applyWrite(agent({ state: "archived", endedReason: "cancelled" }), { kind: "unarchive" }).state, "stopped");
});

test("clearing a rename gives the runtime's title back (#4786)", () => {
  const renamed = pending.applyWrite(agent({ title: "Runtime's" }), { kind: "rename", title: "Mine" });
  assert.equal(renamed.title, "Mine");
  assert.equal(renamed.titleIsPersons, true);
  const cleared = pending.applyWrite(renamed, { kind: "rename", title: "" });
  assert.equal(cleared.title, "Runtime's");
  assert.ok(pending.isSettled(cleared, { kind: "rename", title: "" }));
});

test("the failure line says what failed, as on the Mac and the Remote (#4786)", () => {
  assert.equal(pending.writeFailure({ kind: "archive" }, "Your Mac did not answer."), "Could not archive — your Mac did not answer.");
  assert.equal(pending.writeFailure({ kind: "mute", muted: false }, ""), "Could not unmute.");
});
