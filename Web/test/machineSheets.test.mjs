// Update…, Choose Folders… and Link to Provider… on a machine's row (#4122).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/machineSheets.ts");

const workspace = { provider: "do", providerName: "DigitalOcean", workspace: "w1", workspaceName: "machine-1", workspaceState: "running",
  canStart: true, canStop: true, startWhenUsed: false, current: true };
const registered = { id: "h2", name: "build-box", state: "online" };

test("a row offers Update… only when it needs one, Link to Provider… only when registered, and This Mac none", () => {
  assert.deepEqual(m.machineSheets(registered, "mac", true), { update: false, folders: true, foldersReady: true, link: true });
  assert.deepEqual(m.machineSheets({ ...registered, state: "needsUpdate" }, "mac", true).update, true);
  assert.equal(m.machineSheets({ id: "h1", name: "machine-1", state: "online", workspace }, "mac", true).link, false);
  assert.equal(m.machineSheets(registered, "mac", false).foldersReady, false, "Choose Folders… waits for it to be online");
  assert.deepEqual(m.machineSheets({ id: "mac", name: "Mac", state: "online" }, "mac", true),
    { update: false, folders: false, foldersReady: false, link: false });
});

test("Choose Folders says each found folder as the window does", () => {
  const repo = { folder: "file:///home/alex/work/app/", exists: true, isRepository: true, isFolder: false };
  assert.equal(m.foundPath(repo), "/home/alex/work/app");
  assert.equal(m.foundName(repo), "app");
  assert.equal(m.foundNote(repo), "");
  assert.equal(m.foundNote({ ...repo, isFolder: true }), "· already a folder");
  assert.equal(m.foundNote({ ...repo, isRepository: false }), "· not a git repository");
  assert.equal(m.addFoldersTitle(0), "Add Folders");
  assert.equal(m.addFoldersTitle(1), "Add 1 Folder");
  assert.equal(m.addFoldersTitle(3), "Add 3 Folders");
  assert.equal(m.notAddedLine({ "file:///w/b/": "no", "file:///w/a/": "gone" }), "Not added: a (gone); b (no)");
  assert.equal(m.chooseFoldersWords.intro("box", []), "Add folders on box as folders.");
  assert.equal(m.chooseFoldersWords.intro("box", ["~/src"]), "Folders found on box. Tick the ones to add.");
});

test("Link to Provider… lists each provider's machines, one linked elsewhere named and not to choose", () => {
  const providers = [
    { id: "do", name: "DigitalOcean", workspaces: [{ id: "w1", name: "one", state: "running" }, { id: "w2", name: "two", state: "stopped", host: "h9" }] },
    { id: "empty", name: "Empty", workspaces: [] },
  ];
  const groups = m.linkChoices(providers, [{ id: "h9", name: "other-box", state: "online" }]);
  assert.equal(groups.length, 1, "a provider with no machines is left out");
  const [one, two] = groups[0].workspaces;
  assert.equal(one.key, "do/w1");
  assert.equal(m.linkChoiceLine(one), "Running");
  assert.equal(two.linkedTo, "other-box");
  assert.equal(m.linkChoiceLine(two), "linked to other-box");
});
