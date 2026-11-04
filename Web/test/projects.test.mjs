// A folder's Project (#2317): the same words as ProjectWords in Packages/AgentsKit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("test/projects.ts");
const projects = [{ id: "p-a", name: "Agents", owner: "local", folders: [], mayChange: true }];

test("projects: a folder's project by its id", () => {
  assert.equal(p.projectName("p-a", projects), "Agents");
  assert.equal(p.projectName("p-b", projects), undefined);
  assert.equal(p.projectName(undefined, projects), undefined);
});

test("projects: a failed read says why, and an older control plane says nothing (#2756)", () => {
  assert.equal(p.projectsNotRead(new p.CallFailed(-32601, "Method not found")), undefined);
  assert.equal(p.projectsNotRead(new p.CallFailed(-32000, "The store is busy.")),
    "Couldn't read the projects. The store is busy.");
  assert.equal(p.projectsNotRead(new p.LinkDown()),
    "Couldn't read the projects. The control plane isn't answering. Try again when it's back.");
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

// New Session picks the project, then the machine (#3279), as NewSessionProject in AgentsKit.
test("projects: New Session's projects are the folders by project, in the sidebar's order", () => {
  const row = (host, path, project) => ({ host: { id: host }, folder: { name: path.split("/").pop(), project, folder: { folder: `file://${path}` } } });
  const mac = row("mac", "/src/Agents", "p1");
  const www = row("mac", "/src/www", undefined);
  const clone = row("devbox", "/home/alex/Agents", "p1");
  const other = row("devbox", "/src/www", undefined);
  const choices = p.newSessionProjects([mac, www, clone, other]);
  assert.deepEqual(choices.map((c) => c.name), ["Agents", "www", "www"]);
  assert.deepEqual(choices[0].folders, [mac, clone]);
  assert.equal(choices[1].folders.length, 1);
  // The one last used in the project, else the first.
  assert.equal(p.projectFolder(choices[0], (r) => r === clone), clone);
  assert.equal(p.projectFolder(choices[0], undefined), mac);
});

// Project Settings ▸ Tools ▸ Boards (#3282): each change sends the whole list, each board's name and address.
test("projects: a board is added at the end, trimmed, and only with a name and an address", () => {
  const boards = [{ name: "Platform", url: "https://github.com/orgs/acme/projects/7", forge: "github", key: "acme/7", site: "github.com" }];
  assert.deepEqual(p.boardsWith(boards, " Mobile ", " https://linear.app/acme/team/MOB "), [
    { name: "Platform", url: "https://github.com/orgs/acme/projects/7" },
    { name: "Mobile", url: "https://linear.app/acme/team/MOB" },
  ]);
  assert.equal(p.boardsWith(boards, "", "https://linear.app/acme/team/MOB"), undefined);
  assert.equal(p.boardsWith(boards, "Mobile", "  "), undefined);
});

test("projects: a board is removed by its address, and none is an empty list", () => {
  const boards = [{ name: "A", url: "https://a", forge: "github" }, { name: "B", url: "https://b" }];
  assert.deepEqual(p.boardsWithout(boards, "https://a"), [{ name: "B", url: "https://b" }]);
  assert.deepEqual(p.boardsWithout([{ name: "B", url: "https://b" }], "https://b"), []);
});

test("projects: a board's forge in words, after its name", () => {
  assert.equal(p.boardForge({ name: "A", url: "u", forge: "github" }), "GitHub Projects");
  assert.equal(p.boardForge({ name: "A", url: "u", forge: "atlassian" }), "Jira");
  assert.equal(p.boardForge({ name: "A", url: "u", forge: "linear" }), "Linear team");
  assert.equal(p.boardForge({ name: "A", url: "u" }), "");
});
