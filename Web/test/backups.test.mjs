// Settings ▸ Backups (#1810): what the section says, as the window and the Remote say it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const backups = await load("src/model/backups.ts");

const backup = (extra) => ({ id: "ROOT/20261020T090000Z", machine: "Studio", rootID: "ROOT", madeAt: 0,
  bytes: 12_400_000, agents: 2, thisMachine: true, ...extra });

test("a backup says whose it is, how many agents and its size", () => {
  assert.equal(backups.backupDetail(backup()), "This machine · 2 agents · 12 MB");
  assert.equal(backups.backupDetail(backup({ thisMachine: false, agents: 1, bytes: 900 })), "Studio · 1 agent · 900 bytes");
  assert.equal(backups.confirmTitle(backup({ thisMachine: false })), "Restore the backup of Studio?");
});

test("a restore says what came back and what was here already", () => {
  assert.equal(backups.restoredWords({ restored: 3, skipped: 0 }), "Restored 3 agents, archived.");
  assert.equal(backups.restoredWords({ restored: 1, skipped: 1 }), "Restored 1 agent, archived. 1 was here already.");
  assert.equal(backups.restoredWords({ restored: 0, skipped: 4 }), "Restored 0 agents, archived. 4 were here already.");
});

test("every schedule has words", () => {
  assert.deepEqual(backups.backupEveries.map(backups.everyLabel), ["Never", "Every day", "Every week"]);
});
