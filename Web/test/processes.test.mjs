// A machine's processes (#3453): what its page says, as the window says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const processes = await load("src/model/processes.ts");

test("CPU is of one core, a tenth under 10%", () => {
  assert.equal(processes.cpuWords(0), "0%");
  assert.equal(processes.cpuWords(0.04), "0%");
  assert.equal(processes.cpuWords(2.345), "2.3%");
  assert.equal(processes.cpuWords(152.6), "153%");
});

test("memory is in binary units", () => {
  assert.equal(processes.memoryWords(900), "900 bytes");
  assert.equal(processes.memoryWords(1536), "1.5 KB");
  assert.equal(processes.memoryWords(300 * 1024 * 1024), "300 MB");
  assert.equal(processes.memoryWords(16 * 1024 ** 3), "16 GB");
});

test("the machine says its cores and its memory", () => {
  const machine = { cpuPercent: 12.4, cpuCount: 8, memoryUsed: 7 * 1024 ** 3, memoryTotal: 16 * 1024 ** 3 };
  assert.equal(processes.machineCPUWords(machine), "12% of 8 cores");
  assert.equal(processes.machineCPUWords({ ...machine, cpuCount: 1 }), "12% of 1 core");
  assert.equal(processes.machineMemoryWords(machine), "7.0 GB of 16 GB");
});

test("only the top of a session's processes names it", () => {
  const a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
  const all = [
    { pid: 10, parent: 1, depth: 0, name: "agentsd", cpuPercent: 0, memory: 0 },
    { pid: 20, parent: 10, depth: 1, name: "claude", cpuPercent: 0, memory: 0, agentId: a },
    { pid: 21, parent: 20, depth: 2, name: "node", cpuPercent: 0, memory: 0, agentId: a },
    { pid: 25, parent: 10, depth: 1, name: "bash", cpuPercent: 0, memory: 0, agentId: a },
  ];
  assert.deepEqual(all.map((p) => processes.isSessionsOwn(p, all)), [false, true, false, true]);
});
