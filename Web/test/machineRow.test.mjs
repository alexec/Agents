// A machine's row in the Machines section (#3974): its dot, its menu and swipes, and what Delete and Remove ask.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/machineRow.ts");

const workspace = { provider: "do", providerName: "DigitalOcean", workspace: "w1", workspaceName: "machine-1", workspaceState: "running",
  canStart: true, canStop: true, startWhenUsed: false, current: true };
const made = (state) => ({ id: "h1", name: "machine-1", state, workspace });
const registered = { id: "h2", name: "build-box", state: "online" };
const mac = { id: "mac", name: "Alex's Mac", state: "online" };

test("the dot says only how the machine is", () => {
  assert.equal(m.machineDot(made("online"), true, false), "online");
  assert.equal(m.machineDot(made("stopped"), false, false), "stopped");
  assert.equal(m.machineDot(made("starting"), false, false), "busy");
  assert.equal(m.machineDot(made("stopped"), false, true), "busy", "a Start under way turns");
  assert.equal(m.machineDot(registered, false, false), "offline");
  assert.equal(m.machineDot({ ...registered, state: "needsUpdate" }, true, false), "attention");
});

test("a provider's machine starts, stops and is deleted; a registered one is removed; This Mac has neither", () => {
  assert.deepEqual(m.machineActions(made("stopped"), "mac"), { start: true, stop: false, delete: true, remove: false });
  assert.deepEqual(m.machineActions(made("online"), "mac"), { start: false, stop: true, delete: true, remove: false });
  assert.deepEqual(m.machineActions(made("starting"), "mac"), { start: false, stop: false, delete: true, remove: false });
  assert.deepEqual(m.machineActions(registered, "mac"), { start: false, stop: false, delete: false, remove: true });
  assert.deepEqual(m.machineActions(mac, "mac"), { start: false, stop: false, delete: false, remove: false });
});

test("swipe right starts or stops, swipe left deletes or removes", () => {
  assert.deepEqual(m.machineSwipes(m.machineActions(made("stopped"), "mac")), { leading: "start", trailing: "delete" });
  assert.deepEqual(m.machineSwipes(m.machineActions(made("online"), "mac")), { leading: "stop", trailing: "delete" });
  assert.deepEqual(m.machineSwipes(m.machineActions(registered, "mac")), { leading: null, trailing: "remove" });
  assert.deepEqual(m.machineSwipes(m.machineActions(mac, "mac")), { leading: null, trailing: null });
});

test("Delete says who deletes it and how many sessions stop", () => {
  assert.equal(m.deleteQuestion(made("online"), 0), "Delete machine-1? DigitalOcean deletes this machine and its disk.");
  assert.equal(m.deleteQuestion(made("online"), 1), "Delete machine-1? DigitalOcean deletes this machine and its disk. 1 session on it stops.");
  assert.equal(m.deleteQuestion(made("online"), 2), "Delete machine-1? DigitalOcean deletes this machine and its disk. 2 sessions on it stop.");
  assert.match(m.removeQuestion(registered), /^Remove build-box\? /);
});

test("Delete names the worktrees with work not pushed (#3979)", () => {
  const preview = { host: "h1", name: "machine-1", state: "online", unpushed: [
    { folder: "file:///src/Agents/", worktree: "file:///src/Agents/wt", branch: "agents/fix-3928", ahead: 3 }] };
  assert.equal(m.deleteQuestion(made("online"), 0, preview),
    "Delete machine-1? DigitalOcean deletes this machine and its disk. 1 worktree has work not pushed, which is lost:\nAgents · agents/fix-3928 (3 commits not pushed)");
  assert.equal(m.deleteQuestion(made("stopped"), 0, { ...preview, unpushed: [], unknown: "machine-1 is not online, so it could not be asked." }),
    "Delete machine-1? DigitalOcean deletes this machine and its disk. machine-1 is not online, so it could not be asked.");
});

test("New Machine names the default once there are two providers (#3979)", () => {
  const p = (id, extra = {}) => ({ id, name: id.toUpperCase(), capabilities: ["create"], ...extra });
  assert.deepEqual(m.newMachineItems([p("do")]), [{ label: "New Machine…" }]);
  assert.deepEqual(m.newMachineItems([p("do"), p("docker", { default: true }), p("ro", { capabilities: [] })]),
    [{ label: "New Machine (DOCKER)…" }, { label: "New Machine on DO…", provider: "do" }]);
});

test("a machine being made has a row until one of its name joins", () => {
  const names = (rows) => rows.map((r) => r.name);
  assert.deepEqual(names(m.makingRows(["", "machine-2", "machine-1"], null, [{ name: "machine-1" }])), ["", "machine-2"]);
  // The control plane's list (#4610): Making… while it waits, the reason once it gave up; a linked one, and one a
  // machine of the name joined as, have no row; the page's own name goes once the list has it.
  const providers = [{ id: "do", name: "Do", workspaces: [
    { id: "ws-2", name: "machine-2", state: "running", notJoined: "Made at Do, but it didn’t join in 10 minutes." },
    { id: "ws-5", name: "old", state: "running" },
    { id: "ws-1", name: "machine-1", state: "starting", joining: true },
    { id: "ws-3", name: "machine-3", state: "running", host: "h3", joining: true },
    { id: "ws-4", name: "machine-4", state: "running", joining: true },
  ] }];
  const rows = m.makingRows(["machine-1", ""], providers, [{ name: "machine-4" }]);
  assert.deepEqual(names(rows), ["", "machine-1", "machine-2"]);
  assert.deepEqual(rows[1], { provider: "do", providerName: "Do", workspace: "ws-1", name: "machine-1", notJoined: null });
  assert.equal(rows[2].notJoined, "Made at Do, but it didn’t join in 10 minutes.");
  assert.equal(m.deleteMakingQuestion(rows[2]),
    "Delete machine-2? Do deletes it. Nothing was installed on it, so there is nothing to back up.");
});

test("the icon's colour says the state, the most urgent first (#4113)", () => {
  assert.equal(m.machineIcon("online", false), "accent");
  assert.equal(m.machineIcon("busy", true), "busy", "a change under way wins over a low disk");
  assert.equal(m.machineIcon("offline", false), "failure");
  assert.equal(m.machineIcon("online", true), "failure", "a low disk is red");
  assert.equal(m.machineIcon("attention", true), "failure", "red wins over amber");
  assert.equal(m.machineIcon("attention", false), "attention");
  assert.equal(m.machineIcon("stopped", false), "stopped");
});

test("the icon's shape says the kind", () => {
  assert.equal(m.machineKind(mac, "mac"), "mac");
  assert.equal(m.machineKind(made("online"), "mac"), "cloud");
  assert.equal(m.machineKind(registered, "mac"), "rack");
});
