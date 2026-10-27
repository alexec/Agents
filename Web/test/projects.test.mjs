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
