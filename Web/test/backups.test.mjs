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
  assert.equal(backups.restoredWords({ restored: 1, skipped: 1 }), "Restored 1 agent, archived. 1 agent was here already.");
  assert.equal(backups.restoredWords({ restored: 0, skipped: 4 }), "Nothing to restore: 4 agents were here already.");
  assert.equal(backups.restoredWords({ restored: 0, skipped: 1 }), "Nothing to restore: 1 agent was here already.");
  assert.equal(backups.restoredWords({ restored: 0, skipped: 0 }), "The backup holds no agents.");
});

test("every schedule has words", () => {
  assert.deepEqual(backups.backupEveries.map(backups.everyLabel), ["Never", "Every day", "Every week"]);
});

test("where backups go has words, and the store's sentence only when they go there (#1815)", () => {
  assert.deepEqual(backups.backupTargets.map(backups.targetLabel), ["A folder", "The control plane"]);
  const state = (target) => ({ settings: { every: "daily", keep: 3, target }, folder: "/f", backups: [], making: false });
  assert.equal(backups.backupTarget(state(undefined)), "folder");
  assert.equal(backups.footerWords(state("folder")), backups.backupsFooter);
  assert.match(backups.footerWords(state("control")), /control plane's store, sealed/);
});
