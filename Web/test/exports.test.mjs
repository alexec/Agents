// Export… and Import Agents… (#1001): the parts the page reads and sends, and its words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const e = await load("src/model/exports.ts");

const b64 = (s) => Buffer.from(s).toString("base64");

test("an export is read part by part until the host says the end", async () => {
  const parts = ["one-", "two-", "three"];
  const asked = [];
  const call = async (method, params, host) => {
    asked.push([method, params, host]);
    if (method === "agents/export") return { file: { id: "F", size: 13 }, agents: 2, name: "Fix 2026-10-22.tar.gz" };
    const at = { 0: 0, 4: 1, 8: 2 }[params.offset];
    return { data: b64(parts[at]), end: at === 2 };
  };
  const got = await e.readExport(call, "h1", { agentID: "A" });
  assert.equal(got.name, "Fix 2026-10-22.tar.gz");
  assert.equal(got.agents, 2);
  assert.equal(Buffer.concat(got.parts.map((p) => Buffer.from(p))).toString(), "one-two-three");
  assert.deepEqual(asked.map(([m, p, h]) => [m, p.offset, h]),
    [["agents/export", undefined, "h1"], ["agents/exportRead", 0, "h1"], ["agents/exportRead", 4, "h1"], ["agents/exportRead", 8, "h1"]]);
});

test("an import is sent in parts at their offsets, then imported", async () => {
  const bytes = new Uint8Array(e.importPartSize * 2 + 10).map((_, i) => i % 251);
  const sent = [];
  const call = async (method, params) => {
    if (method === "agents/importUpload") { sent.push(params); return {}; }
    assert.equal(method, "agents/import");
    assert.equal(params.upload, "U");
    // Into the folder whose menu was used (#2389).
    assert.equal(params.folder, "file:///tmp/B/");
    return { restored: 2, skipped: 1 };
  };
  const result = await e.sendImport(call, "h1", bytes, "U", "file:///tmp/B/");
  assert.deepEqual(result, { restored: 2, skipped: 1 });
  assert.deepEqual(sent.map((p) => p.offset), [0, e.importPartSize, e.importPartSize * 2]);
  assert.deepEqual(Buffer.concat(sent.map((p) => Buffer.from(p.data, "base64"))), Buffer.from(bytes));
});

test("the words say what an import did, as the window's", () => {
  assert.equal(e.importedWords({ restored: 1, skipped: 0 }), "Imported 1 agent, archived.");
  assert.equal(e.importedWords({ restored: 3, skipped: 0 }), "Imported 3 agents, archived.");
  assert.equal(e.importedWords({ restored: 2, skipped: 1 }), "Imported 2 agents, archived. 1 was skipped: already here, or deleted here.");
  assert.equal(e.importedWords({ restored: 0, skipped: 2 }), "Imported no agents. 2 were skipped: already here, or deleted here.");
  assert.equal(e.importedWords({ restored: 0, skipped: 0 }), "There were no agents to import.");
  assert.equal(e.importedWords({ restored: 2, skipped: 0 }, "Web"), "Imported 2 agents into Web, archived.");
});

test("a read says how far it is, and Cancel stops it between parts (#2437)", async () => {
  const parts = ["one-", "two-", "three"];
  const call = async (method, params) => {
    if (method === "agents/export") return { file: { id: "F", size: 13 }, agents: 2, name: "Fix.tar.gz" };
    const at = { 0: 0, 4: 1, 8: 2 }[params.offset];
    return { data: b64(parts[at]), end: at === 2 };
  };
  const seen = [];
  let agents = null;
  await e.readExport(call, "h1", { agentID: "A" }, { progress: (d, w) => seen.push([d, w]) }, (n) => { agents = n; });
  assert.deepEqual(seen, [[4, 13], [8, 13], [13, 13]]);
  assert.equal(agents, 2);
  let cancel = false;
  await assert.rejects(e.readExport(call, "h1", { agentID: "A" },
    { progress: () => { cancel = true; }, cancelled: () => cancel }), e.Cancelled);
});

test("a cancelled import imports nothing (#2437)", async () => {
  const bytes = new Uint8Array(e.importPartSize * 3);
  const asked = [];
  const call = async (method) => { asked.push(method); return {}; };
  let cancel = false;
  await assert.rejects(e.sendImport(call, "h1", bytes, "U", undefined,
    { progress: () => { cancel = true; }, cancelled: () => cancel }), e.Cancelled);
  assert.deepEqual(asked, ["agents/importUpload"]);
});

test("the busy lines say what is going on, as the window's (#2437)", () => {
  assert.equal(e.exportingWords(null), "Making the export…");
  assert.equal(e.exportingWords(1), "Exporting 1 agent…");
  assert.equal(e.exportingWords(12), "Exporting 12 agents…");
  assert.equal(e.importingWords(false), "Sending the export…");
  assert.equal(e.importingWords(true), "Importing the agents…");
});
