// A machine's page (#3626): a page per machine under Machines, and the words for its disks, as the window says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const n = await load("src/model/nav.ts");
const disk = await load("src/model/disk.ts");

test("each machine is a page after Machines ▸ Machines, the Mac first", () => {
  const more = n.machinePages([{ id: "b", name: "zeta" }, { id: "a", name: "alpha" }, { id: "m", name: "studio" }], "m");
  assert.deepEqual(more.map((p) => p.title), ["studio", "alpha", "zeta"]);
  assert.deepEqual(n.pagesShown("machines", false, undefined, more).map((p) => p.id).slice(0, 5),
    ["machines", "machine-m", "machine-a", "machine-b"]);
  assert.equal(n.openPage("machines", "machine-a", false, more).draw.host, "a");
  assert.equal(n.openPage("machines", "machine-gone", false, more).id, "machines", "a machine gone opens the list");
  assert.deepEqual(n.pagesShown("machines", false).map((p) => p.id), ["machines"], "no machines, no pages; Connectors is in Your setup (#3632)");
});

test("a disk says free of total, and its level", () => {
  const alarm = (level) => ({ reading: { volume: "Macintosh HD", mount: "/", freeBytes: 240e9, totalBytes: 1000e9 }, level, threshold: 0, worktrees: [] });
  assert.equal(disk.freeWords(alarm("ok")), "240.0 GB free of 1000.0 GB (24%)");
  assert.equal(disk.levelWords("ok"), "OK");
  assert.equal(disk.levelWords("low"), "Low");
  assert.equal(disk.levelWords("critical"), "Almost full");
});
