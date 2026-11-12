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
  assert.deepEqual(n.pagesShown("machines", false).map((p) => p.id), ["machines"], "no machines, no pages; Connectors is in Settings ▸ You (#3998)");
});

test("a disk says free of total, and its level", () => {
  const alarm = (level) => ({ reading: { volume: "Macintosh HD", mount: "/", freeBytes: 240e9, totalBytes: 1000e9 }, level, threshold: 0, worktrees: [] });
  assert.equal(disk.freeWords(alarm("ok")), "240.0 GB free of 1000.0 GB (24%)");
  assert.equal(disk.levelWords("ok"), "OK");
  assert.equal(disk.levelWords("low"), "Low");
  assert.equal(disk.levelWords("critical"), "Almost full");
});

test("the summary names one disk: the worst, then the folders' own, then the fullest (#3743)", () => {
  const d = (mount, freeGB, level = "ok") => ({ reading: { volume: mount, mount, freeBytes: freeGB * 1e9, totalBytes: 1000e9 }, level, threshold: 0, worktrees: [] });
  const root = d("/", 400), data = d("/Volumes/Data", 100), low = d("/Volumes/Old", 900, "low");
  assert.equal(disk.headline([root, data, low], ["/Users/a/x"]).reading.mount, "/Volumes/Old");
  assert.equal(disk.headline([root, data], ["/Users/a/x", "/Volumes/Data2/y"]).reading.mount, "/");
  assert.equal(disk.headline([root, data], ["/Volumes/Data/y"]).reading.mount, "/Volumes/Data");
  assert.equal(disk.headline([root, data], []).reading.mount, "/Volumes/Data", "no folders: the one with least free");
  assert.equal(disk.headline([], []), undefined);
  assert.equal(disk.summaryWords(root), "Disk 400.0 GB free");
  assert.equal(disk.summaryWords(low), "Disk 900.0 GB free · Low");
});

test("the detail is closed under rows that say how much (#3743)", async () => {
  const w = await load("src/model/worktrees.ts");
  const p = await load("src/model/processes.ts");
  const r = await load("src/model/runtimes.ts");
  assert.equal(w.folderLine("Agents", 4), "Agents · 4 worktrees");
  assert.equal(w.folderLine("Agents", 1), "Agents · 1 worktree");
  const proc = (cpuPercent, memory) => ({ pid: 1, name: "x", depth: 0, cpuPercent, memory });
  assert.equal(p.processesLine({ processes: [proc(3, 512 * 1024 * 1024), proc(1.5, 512 * 1024 * 1024)], omitted: 2 }), "Processes (4) · 4.5% · 1.0 GB");
  const status = (availability) => ({ runtime: { id: "x", name: "X" }, availability });
  assert.equal(r.isInstalled(status({ available: { path: "/p" } })), true);
  assert.equal(r.isInstalled(status({ needsSignIn: {} })), true);
  assert.equal(r.isInstalled(status({ missing: { lookedIn: [] } })), false);
  assert.equal(r.isInstalled(status({ installFailed: { reason: "x" } })), false);
});

test("a runtime's row offers Update when the app carries a newer copy, and none is going (#4174)", async () => {
  const r = await load("src/model/runtimes.ts");
  const status = (outdated, availability, recipe = true) =>
    ({ runtime: { id: "x", name: "X", ...(recipe ? { install: { steps: [] } } : {}) }, availability, outdated });
  assert.equal(r.offersUpdate(status(true, { available: { path: "/p" } })), true);
  assert.equal(r.offersUpdate(status(false, { available: { path: "/p" } })), false, "up to date");
  assert.equal(r.offersUpdate(status(true, { installing: {} })), false, "already updating");
  assert.equal(r.offersUpdate(status(true, { available: { path: "/p" } }, false)), false, "no recipe");
});

test("the summary says the load and the level, and a line why at near and full (#4582)", async () => {
  const c = await load("src/model/capacity.ts");
  const usage = (capacity, o = {}) => ({ cpuPercent: 82, cpuCount: 10, memoryUsed: 14, memoryTotal: 16,
    loadPerCore: 2.4, loadPerCore5: 2.1, memoryPressure: "normal", swapUsedPercent: 3, capacity, ...o });
  assert.equal(c.loadWords(2.44), "Load 2.4 per core");
  assert.equal(c.levelWords("ok"), null);
  assert.equal(c.levelWords(undefined), null);
  assert.equal(c.levelWords("near"), "Near capacity");
  assert.equal(c.levelWords("full"), "At capacity");
  assert.equal(c.warningWords(usage("ok"), "This Mac"), null);
  assert.equal(c.warningWords(usage("near", { loadPerCore: 1.8 }), "This Mac"), "This Mac is near capacity: load 1.8 per core.");
  assert.equal(c.warningWords(usage("near", { loadPerCore: 0.4, memoryPressure: "warn" }), "studio"), "studio is near capacity: memory pressure warn.");
  assert.equal(c.warningWords(usage("full", { loadPerCore: 3.1 }), "This Mac"), "This Mac is at capacity: load 3.1 per core.");
  assert.equal(c.warningWords(usage("full", { loadPerCore: 1, memoryPressure: "critical" }), "This Mac"), "This Mac is at capacity: memory pressure critical.");
  assert.equal(c.warningWords(usage("full", { loadPerCore: 1, swapUsedPercent: 62 }), "This Mac"), "This Mac is at capacity: swap 62% used.");
  assert.equal(c.warningWords(usage("near", { loadPerCore: 1.2 }), "This Mac"), "This Mac is near capacity: load 1.2 per core.", "coming down: the load");
  assert.equal(c.detailWords(usage("ok")), "Load 2.4 per core over 1 minute, 2.1 over 5 · Memory pressure normal · Swap 3% used");
  assert.equal(c.detailWords(usage("ok", { loadPerCore5: undefined, memoryPressure: undefined, swapUsedPercent: undefined })), "Load 2.4 per core over 1 minute");
  assert.equal(c.detailWords(usage(undefined, { loadPerCore: undefined })), null);
  assert.equal(c.queuedWords(0), null);
  assert.equal(c.queuedWords(1), "1 start queued");
  assert.equal(c.queuedWords(2), "2 starts queued");
});

test("the waits for the machine say why (#4748)", async () => {
  const c = await load("src/model/capacity.ts");
  assert.equal(c.leasesInLineWords(0), null);
  assert.equal(c.leasesInLineWords(1), "1 lease in line for the machine");
  assert.equal(c.leasesInLineWords(2), "2 leases in line for the machine");
  const member = { agentID: "a", askedAt: 0, isCallOpen: true };
  assert.equal(c.leasesInLine([{ name: "build", line: [member, member], capacityWait: "this Mac is near capacity" },
    { name: "screen", line: [member] }]), 2);
  assert.equal(c.startLineWords("this Mac is near capacity"), "◷ In line to start · this Mac is near capacity");
  assert.equal(c.heldForCapacityWords("this Mac is at capacity"), "Held for capacity: this Mac is at capacity");
});
