// A folder's Project (#2317): the same words as ProjectWords in Packages/AgentsKit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/projects.ts");
const projects = [{ id: "p-a", name: "Agents", owner: "local", folders: [], mayChange: true }];

test("projects: a folder's project by its id", () => {
  assert.equal(p.projectName("p-a", projects), "Agents");
  assert.equal(p.projectName("p-b", projects), undefined);
  assert.equal(p.projectName(undefined, projects), undefined);
  assert.equal(p.unknownProject("p-b"), "Not on the control plane yet (p-b)");
});

test("projects: a name is taken in any case, but not by itself", () => {
  assert.equal(p.projectTaken(" agents ", projects), true);
  assert.equal(p.projectTaken("agents", projects, "p-a"), false);
  assert.equal(p.projectTaken("Other", projects), false);
});

// Console ▸ Projects (#2671).
test("projects: the owner by name, and the id for one not listed", () => {
  const people = [{ id: "u-1", name: "Alex" }];
  assert.equal(p.projectOwner("u-1", people), "Alex");
  assert.equal(p.projectOwner("u-2", people), "u-2");
  assert.equal(p.projectOwner("", people), "Nobody");
});

test("projects: folders by machine, then by name", () => {
  const project = { id: "p-a", name: "Agents", owner: "u-1", mayChange: true, folders: [
    { machine: "m-2", folder: "file:///b", name: "b" },
    { machine: "m-1", folder: "file:///z", name: "z" },
    { machine: "m-1", folder: "file:///a", name: "a" },
  ] };
  const names = { "m-1": "Mac", "m-2": "Linux" };
  assert.deepEqual(p.projectFolders(project, (id) => names[id]).map((r) => `${r.machine} ${r.folder.name}`),
    ["Linux b", "Mac a", "Mac z"]);
});

test("projects: Remove is off with folders in it, or for one not yours", () => {
  assert.equal(p.removeRefusal(projects[0]), null);
  assert.match(p.removeRefusal({ ...projects[0], folders: [{ machine: "m", folder: "file:///a", name: "a" }] }), /Move its folders/);
  assert.match(p.removeRefusal({ ...projects[0], mayChange: false }), /owner or an admin/);
});
