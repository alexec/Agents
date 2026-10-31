// The one sidebar (#151, #499): folds kept in localStorage by host and folder, the smart groups and
// what they gather, Activity pages and a folder's archive in the address, and what the Activity
// rows say at a glance.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

class Memory {
  items = new Map();
  getItem(key) { return this.items.get(key) ?? null; }
  setItem(key, value) { this.items.set(key, String(value)); }
}

test("a fold is kept, and read back by the next visit", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  first.set("mac", "file:///w/Agents/", true);
  const next = new Folds(storage);
  assert.equal(next.isOpen("mac", "file:///w/Agents"), true, "a trailing slash is the same folder");
  assert.equal(next.isOpen("box", "file:///w/Agents"), false, "the same folder on another host folds apart");
  next.set("mac", "file:///w/Agents", false);
  assert.equal(new Folds(storage).isOpen("mac", "file:///w/Agents"), false);
});

test("Pinned and Needs You start open, Working and Unread folded, and a fold of one is kept (#495)", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.isSmartOpen("pinned"), true);
  assert.equal(first.isSmartOpen("needsYou"), true);
  assert.equal(first.isSmartOpen("working"), false);
  assert.equal(first.isSmartOpen("unread"), false);
  first.setSmart("needsYou", false);
  first.setSmart("working", true);
  const next = new Folds(storage);
  assert.equal(next.isSmartOpen("needsYou"), false, "kept folded");
  assert.equal(next.isSmartOpen("pinned"), true, "only that group");
  assert.equal(next.isSmartOpen("working"), true, "kept open");
  assert.equal(next.isOpen("mac", "file:///w/a"), false, "no folder's fold is touched");
  assert.deepEqual(JSON.parse(storage.getItem("agents.sidebar.folded")), ["smart:needsYou"]);
  assert.deepEqual(JSON.parse(storage.getItem("agents.sidebar.folds")), ["smart:working"]);
});

test("a folder's Workflows fold starts folded and is kept per folder (#885)", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.isWorkflowsOpen("mac", "file:///w/a"), false, "folded until opened");
  first.setWorkflows("mac", "file:///w/a", true);
  const next = new Folds(storage);
  assert.equal(next.isWorkflowsOpen("mac", "file:///w/a/"), true, "kept open");
  assert.equal(next.isWorkflowsOpen("mac", "file:///w/b"), false, "only that folder");
  assert.equal(next.isWorkflowsOpen("box", "file:///w/a"), false, "the same folder on another host folds apart");
  assert.equal(next.isOpen("mac", "file:///w/a"), false, "the folder's own fold is not touched");
});

test("a folder's Sessions fold starts open and is kept per folder (#2312)", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.isSessionsOpen("mac", "file:///w/a"), true, "open until folded");
  first.setSessions("mac", "file:///w/a", false);
  const next = new Folds(storage);
  assert.equal(next.isSessionsOpen("mac", "file:///w/a/"), false, "kept folded");
  assert.equal(next.isSessionsOpen("mac", "file:///w/b"), true, "only that folder");
  assert.equal(next.isSessionsOpen("box", "file:///w/a"), true, "the same folder on another host folds apart");
  assert.equal(next.isWorkflowsOpen("mac", "file:///w/a"), false, "the Workflows fold is not touched");
  next.setSessions("mac", "file:///w/a", true);
  assert.deepEqual(JSON.parse(storage.getItem("agents.sidebar.folded")), [], "open again is the first state");
});

const agent = (id, createdAt, fields = {}) => ({ id, createdAt, lastActivityAt: createdAt, state: "finished",
  cwd: "file:///w/a", title: id, ...fields });

test("smart groups gather by what a session wants, newest started first (#495)", async () => {
  const { smartAgents, sessionMark } = await load("src/model/sidebar.ts");
  const live = [
    agent("asked", 1, { state: "waitingOnUser" }),
    agent("old-work", 2, { state: "running" }),
    agent("new-work", 5, { state: "running" }),
    agent("unread", 3, { isUnread: true }),
    agent("read", 4),
  ];
  assert.deepEqual(smartAgents("needsYou", live).map((a) => a.id), ["asked"]);
  assert.deepEqual(smartAgents("working", live).map((a) => a.id), ["new-work", "old-work"], "by start, not activity");
  assert.deepEqual(smartAgents("unread", live).map((a) => a.id), ["unread"]);
  assert.deepEqual(smartAgents("working", live, { label: null, text: "old" }).map((a) => a.id), ["old-work"], "a search narrows it");
  assert.deepEqual(live.map(sessionMark), ["needsYou", "working", "working", "done", "done"], "one ring, read or not (#1323)");
  assert.equal(sessionMark(agent("paused", 1, { state: "stopped", endedReason: "cancelled" })), "paused", "in the accent (#630)");
  assert.equal(sessionMark(agent("queued", 1, { state: "queued" })), "queued", "its own mark (#630)");
  assert.equal(sessionMark(agent("gone", 1, { state: "archived" })), null, "its own status mark");
});

test("a working session running a tool shows a wrench, named by its tool; thinking keeps the spinner (#1902)", async () => {
  const { sessionMark, runningTool, runningToolLabel } = await load("src/model/sidebar.ts");
  const tooling = agent("tool", 1, { state: "running", runningTool: "swift test" });
  assert.equal(sessionMark(tooling), "tool");
  assert.equal(runningTool(tooling), "swift test");
  assert.equal(runningToolLabel("swift test"), "Running: swift test");
  assert.equal(sessionMark(agent("thinking", 1, { state: "running" })), "working");
  // A tool left on a record that is not running any more says nothing.
  assert.equal(runningTool(agent("done", 1, { runningTool: "ls" })), null);
});

test("only an unread session in Done is drawn unread, though one that asks still counts (#1323)", async () => {
  const { drawsUnread, showsUnread } = await load("src/model/groups.ts");
  const asking = agent("asking", 1, { isUnread: true, report: { outcome: "needs_answer", message: "Which?", at: 1 } });
  assert.equal(showsUnread(asking), true);
  assert.equal(drawsUnread(asking), false, "Needs You is never bold");
  assert.equal(drawsUnread(agent("done", 1, { isUnread: true })), true);
  assert.equal(drawsUnread(agent("read", 1)), false);
  assert.equal(drawsUnread(agent("archive", 1, { isUnread: true, archiveRequest: { requested: { at: 1 } } })), true,
    "asking to be archived is still done");
});

test("Needs You gathers what an agent asked to have archived, each listed once (#584, #587, #773)", async () => {
  const { smartAgents, smartRows, smartTitles, home, sessionMark } = await load("src/model/sidebar.ts");
  const asked = { requested: { at: 1 } };
  const live = [
    agent("done", 1, { archiveRequest: asked }),
    agent("partly", 2, { archiveRequest: asked, report: { outcome: "nothing_to_do", message: "m", at: 1 } }),
    agent("later", 3, { state: "running", archiveRequest: { whenTurnEnds: { since: 1 } } }),
    agent("asked-unread", 4, { archiveRequest: asked, isUnread: true }),
    agent("none", 5),
  ];
  assert.deepEqual(smartAgents("needsYou", live).map((a) => a.id), ["asked-unread", "partly", "done"],
    "asked, and nothing to do, once each; not set to ask");
  assert.deepEqual(smartAgents("unread", live).map((a) => a.id), [], "asking unread is in Needs You alone");
  assert.deepEqual(smartAgents("working", live).map((a) => a.id), ["later"]);
  assert.deepEqual(live.map((a) => home(a, false)), ["needsYou", "needsYou", "working", "needsYou", null]);
  assert.deepEqual(smartRows, ["pinned", "needsYou", "working", "unread"], "no Approve Archiving");
  assert.deepEqual(Object.keys(smartTitles), ["pinned", "needsYou", "working", "unread"]);
  assert.deepEqual(live.map(sessionMark), ["asksToArchive", "asksToArchive", "working", "asksToArchive", "done"], "nothing to do asks too (#1916)");
});

const approval = (kind, key, fields = {}) => ({ kind, key, title: key, line: "New with the last pull",
  actions: ["approve", "deny"], ...fields });

test("Needs You lists every folder's approvals, oldest first, but a session's archive request (#773)", async () => {
  const { smartApprovals } = await load("src/model/sidebar.ts");
  const folders = [
    { folder: "a", approvals: [approval("workflow", "nightly", { since: 30 }), approval("archive", "s1", { since: 1 })] },
    { folder: "b", approvals: [approval("mcpServer", "github", { since: 10 }), approval("plugin", "lint")] },
    { folder: "c" },
    { folder: "d", approvals: [approval("file", ".agents/pins.json", { since: 20, line: "Changed by Claude" })] },
  ];
  const listed = smartApprovals(folders);
  assert.deepEqual(listed.map(({ folder, approval }) => `${folder}:${approval.key}`),
    ["b:lint", "b:github", "d:.agents/pins.json", "a:nightly"], "no time first, then oldest; the archive request is its session's row");
  assert.equal(smartApprovals([{ folder: "c" }]).length, 0);
});

test("a search matches an approval's title, kind and grey line (#773)", async () => {
  const { smartApprovals } = await load("src/model/sidebar.ts");
  const folders = [{ folder: "a", approvals: [
    approval("mcpServer", "github"),
    approval("workflow", "nightly", { line: "Changed since you approved it" }),
    approval("archive", "s1"),
  ] }];
  const keys = (query) => smartApprovals(folders, query).map(({ approval }) => approval.key);
  assert.deepEqual(keys("GitHub"), ["github"], "the title, in any case");
  assert.deepEqual(keys("connector"), ["github"], "the kind in words");
  assert.deepEqual(keys(" since you "), ["nightly"], "the grey line, trimmed");
  assert.deepEqual(keys("archive"), [], "never the session's archive request");
  assert.deepEqual(keys(""), ["github", "nightly"]);
});

test("an approval's words are the window's, per kind (#773)", async () => {
  const { actionWord, approvalID, approvalLine, explanations, kindWords } = await load("src/model/approvals.ts");
  assert.deepEqual(["mcpServer", "workflow", "plugin", "file", "archive"].map((k) => kindWords[k]),
    ["Connector", "Workflow", "Plugin", "File", "Archive"]);
  const words = (kind) => ["approve", "deny", "requestChanges"].map((a) => actionWord(kind, a));
  assert.deepEqual(words("mcpServer"), ["Approve", "Deny", "Request Changes"]);
  assert.deepEqual(words("workflow"), ["Approve", "Deny", "Request Changes"]);
  assert.deepEqual(words("plugin"), ["Approve", "Deny", "Request Changes"]);
  assert.deepEqual(words("file"), ["Keep", "Undo", "Request Changes"]);
  assert.deepEqual(words("archive"), ["Archive", "Keep Session", "Request Changes"]);
  assert.equal(approvalLine(approval("mcpServer", "github")), "Connector · New with the last pull");
  assert.equal(approvalID(approval("file", ".agents/mcp.json")), "file:.agents/mcp.json");
  assert.equal(explanations.archive, "The session asked to be archived. Keep Session takes the request away and leaves it where it is.");
  assert.ok(explanations.mcpServer.endsWith(".agents/mcp.json changes again."));
});

test("a folder's sessions are one list, the pinned out of it; Pinned keeps pin order (#495)", async () => {
  const { folderSessions, pinnedSessions, pinnedWorkflows } = await load("src/model/sidebar.ts");
  const live = [agent("a", 1), agent("b", 3), agent("c", 2)];
  assert.deepEqual(folderSessions(live, []).map((a) => a.id), ["b", "c", "a"], "newest started first, no headings");
  assert.deepEqual(folderSessions(live, ["b"]).map((a) => a.id), ["c", "a"]);
  assert.deepEqual(pinnedSessions(live, ["a", "gone", "b"]).map((a) => a.id), ["a", "b"], "pin order, held only");
  const flow = (workflowID, isArchived = false) => ({ workflow: { workflowID }, isArchived });
  assert.deepEqual(pinnedWorkflows([flow("x"), flow("y", true), flow("z")], ["z", "y", "x"]).map((w) => w.workflow.workflowID),
    ["z", "x"], "an archived one only under Archived");
});

test("a session is listed once, in its first group: Pinned, Needs You, Working, Unread, else its folder (#587)", async () => {
  const { home, smartAgents, folderSessions } = await load("src/model/sidebar.ts");
  const live = [
    agent("pinned-asking", 1, { state: "waitingOnUser" }),
    agent("asking-unread", 2, { state: "waitingOnUser", isUnread: true }),
    agent("working-unread", 3, { state: "running", isUnread: true }),
    agent("unread", 4, { isUnread: true }),
    agent("read", 5),
  ];
  const pins = ["pinned-asking"];
  assert.deepEqual(live.map((a) => home(a, pins.includes(a.id))), ["pinned", "needsYou", "working", "unread", null]);
  assert.deepEqual(smartAgents("needsYou", live, undefined, pins).map((a) => a.id), ["asking-unread"], "the pinned only in Pinned");
  assert.deepEqual(smartAgents("working", live, undefined, pins).map((a) => a.id), ["working-unread"]);
  assert.deepEqual(smartAgents("unread", live, undefined, pins).map((a) => a.id), ["unread"], "not those busy");
  assert.deepEqual(folderSessions(live, pins).map((a) => a.id), ["read"], "its folder has the rest");
});

test("Unread keeps the session opened from it in its place (#495)", async () => {
  const { withKept } = await load("src/model/sidebar.ts");
  const shown = [agent("new", 5), agent("old", 1)];
  assert.deepEqual(withKept(shown, agent("mid", 3)).map((a) => a.id), ["new", "mid", "old"]);
  assert.deepEqual(withKept(shown, agent("oldest", 0)).map((a) => a.id), ["new", "old", "oldest"]);
  assert.deepEqual(withKept(shown, shown[0]).map((a) => a.id), ["new", "old"], "already there, not twice");
  assert.deepEqual(withKept(shown, undefined).map((a) => a.id), ["new", "old"]);
});

test("the session Unread keeps is not under its folder too, until another is opened (#689)", async () => {
  const { keepsInUnread, folderSessions } = await load("src/model/sidebar.ts");
  const live = [agent("opened", 2), agent("read", 1), agent("working", 3, { state: "running" })];
  assert.equal(keepsInUnread(live[0], []), true, "read now, still kept");
  assert.deepEqual(folderSessions(live, [], undefined, "opened").map((a) => a.id), ["read"]);
  assert.deepEqual(folderSessions(live, []).map((a) => a.id), ["opened", "read"], "under its folder once let go");
  assert.equal(keepsInUnread(live[0], ["opened"]), false, "pinned, it is in Pinned");
  assert.equal(keepsInUnread(live[2], []), false, "working, it is in Working");
  assert.equal(keepsInUnread(agent("gone", 4, { state: "archived" }), []), false);
});

test("a group turned off is not drawn, and its sessions go to the next group they fit, or under their folder (#846)", async () => {
  const { smartAgents, smartRows, folderSessions, keepsInUnread, pinnedSessions } = await load("src/model/sidebar.ts");
  const live = [
    agent("pinned-asking", 1, { state: "waitingOnUser" }),
    agent("asking", 2, { state: "waitingOnUser" }),
    agent("working", 3, { state: "running" }),
    agent("archiving", 4, { isUnread: true, archiveRequest: { requested: { at: 1 } } }),
    agent("unread", 5, { isUnread: true }),
    agent("read", 6),
  ];
  const pins = ["pinned-asking"];
  const all = new Set(smartRows);
  const without = (...off) => new Set(smartRows.filter((row) => !off.includes(row)));
  // What each group lists, as the sidebar draws it: Pinned by its pins while on, the rest by `home`.
  const listing = (on) => {
    const rows = Object.fromEntries(smartRows.map((row) => [row, !on.has(row) ? []
      : row === "pinned" ? pinnedSessions(live, pins).map((a) => a.id)
      : smartAgents(row, live, undefined, pins, on).map((a) => a.id)]));
    const own = folderSessions(live, pins, undefined, undefined, on).map((a) => a.id);
    const every = [...Object.values(rows).flat(), ...own];
    assert.equal(new Set(every).size, every.length, "once each");
    assert.equal(every.length, live.length, "none left out");
    return { rows, own };
  };

  listing(all);
  // Pinned off: the pinned session that asks is in Needs You.
  const noPins = listing(without("pinned"));
  assert.deepEqual(noPins.rows.pinned, []);
  assert.deepEqual(new Set(noPins.rows.needsYou), new Set(["pinned-asking", "asking", "archiving"]));
  // Needs You off: the unread one asking to be archived goes to Unread, the one asking under its folder.
  const noNeeds = listing(without("needsYou"));
  assert.deepEqual(new Set(noNeeds.rows.unread), new Set(["archiving", "unread"]));
  assert.ok(noNeeds.own.includes("asking"));
  // Working off: the working session goes under its folder.
  assert.ok(listing(without("working")).own.includes("working"));
  // Every group off: all six under the folder, the pinned one too, and Unread keeps nothing.
  const none = listing(new Set());
  assert.deepEqual(new Set(none.own), new Set(live.map((a) => a.id)));
  assert.equal(keepsInUnread(live[5], [], new Set()), false, "Unread off keeps nothing");
  assert.equal(keepsInUnread(live[5], ["read"], without("pinned")), true, "a pin counts only while Pinned is on");
});

test("the groups on round-trip through what this browser keeps: the groups off (#846)", async () => {
  const { smartRowsOn, smartRowsOff } = await load("src/model/smartGroups.ts");
  const all = ["pinned", "needsYou", "working", "unread"];
  assert.deepEqual([...smartRowsOn("")], all);
  assert.deepEqual([...smartRowsOn(null)], ["pinned", "needsYou"], "nothing kept: Working and Unread off (#979)");
  assert.deepEqual([...smartRowsOn(undefined)], ["pinned", "needsYou"]);
  assert.equal(smartRowsOff(new Set(all)), "");
  assert.equal(smartRowsOff(new Set(["unread", "needsYou"])), "pinned,working", "in the sidebar's order");
  assert.deepEqual([...smartRowsOn("pinned,working,gone")], ["needsYou", "unread"], "a name not a group's is passed over");
  for (const off of ["", "pinned", "needsYou,unread", "pinned,needsYou,working,unread"]) {
    assert.equal(smartRowsOff(smartRowsOn(off)), off);
  }
});

test("Settings is a section in the address on its own (#846, #2141)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { parseRoute, routeHash } = await load("src/route.ts");
    assert.equal(routeHash({ nav: "settings", host: "mac", folder: "file:///w/a" }), "#/settings");
    assert.deepEqual(parseRoute("#/settings"), { nav: "settings" });
    assert.deepEqual(parseRoute("#/a/settings"), {}, "not an Activity page: the Overview");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("New Session starts in the folder last started in, while it is live (#495)", async () => {
  const { newSessionFolder, rememberedFolder, rememberFolder } = await load("src/model/sidebar.ts");
  const live = [{ host: "mac", folder: "file:///w/a/" }, { host: "box", folder: "file:///w/b" }];
  assert.deepEqual(newSessionFolder(live, { host: "box", folder: "file:///w/b/" }, undefined), live[1]);
  assert.deepEqual(newSessionFolder(live, { host: "mac", folder: "file:///w/gone" }, live[1]), live[1], "else the one open");
  assert.deepEqual(newSessionFolder(live, undefined, undefined), live[0], "else the first");
  assert.equal(newSessionFolder([], undefined, undefined), undefined);
  const storage = new Memory();
  assert.equal(rememberedFolder(storage), undefined);
  rememberFolder(storage, live[1]);
  assert.deepEqual(rememberedFolder(storage), live[1]);
  storage.setItem("agents.sidebar.newSessionFolder", "{bad");
  assert.equal(rememberedFolder(storage), undefined, "stored badly, none");
});

test("a folder's archive is in the address (#499)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { parseRoute, routeHash } = await load("src/route.ts");
    const hash = routeHash({ host: "mac", folder: "file:///w/a", archive: true });
    assert.equal(hash, "#/h/mac/p/file%3A%2F%2F%2Fw%2Fa/ar/1");
    assert.deepEqual(parseRoute(hash), { host: "mac", folder: "file:///w/a", archive: true });
    assert.equal(routeHash({ host: "mac", folder: "file:///w/a", session: "s", archive: true }),
      "#/h/mac/p/file%3A%2F%2F%2Fw%2Fa/s/s", "a session opened from it is a page of its own");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("folds stored badly, or a storage that refuses, leave everything folded", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  storage.setItem("agents.sidebar.folds", "{not json");
  const folds = new Folds(storage);
  assert.equal(folds.isOpen("mac", "file:///w/a"), false);
  const refusing = { getItem: () => null, setItem: () => { throw new Error("quota"); } };
  const held = new Folds(refusing);
  held.set("mac", "file:///w/a", true);
  assert.equal(held.isOpen("mac", "file:///w/a"), true, "held for this visit");
});

test("an Activity page is a page of Machines or Reports (#2141), and an unknown one is ignored", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { parseRoute, routeHash } = await load("src/route.ts");
    assert.equal(routeHash({ nav: "reports", section: "events", host: "mac", folder: "file:///w/a" }), "#/reports/events");
    assert.deepEqual(parseRoute("#/a/spending"), { nav: "reports", section: "usage" });
    assert.deepEqual(parseRoute("#/a/time"), { nav: "reports", section: "usage" });
    assert.deepEqual(parseRoute("#/a/milestones"), { nav: "reports", section: "milestones" });
    assert.deepEqual(parseRoute("#/a/mcp"), { nav: "machines", section: "mcp" }, "Connectors has a page of its own (#589)");
    assert.deepEqual(parseRoute("#/h/mac/p/file%3A%2F%2F%2Fw%2Fa/m/1"), { host: "mac", folder: "file:///w/a", mcp: true },
      "a folder's Connectors has a page of its own (#753)");
    assert.equal(routeHash({ host: "mac", folder: "file:///w/a", mcp: true }), "#/h/mac/p/file%3A%2F%2F%2Fw%2Fa/m/1");
    assert.deepEqual(parseRoute("#/a/settings"), {});
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("the Connectors row: none hosted says nothing, one stopped in use is the count (#589)", async () => {
  const { hostedTally } = await load("src/model/hostedMCP.ts");
  const server = (name, state) => ({ name, state, restarts: 0, users: 1 });
  assert.equal(hostedTally([]), null);
  assert.deepEqual(hostedTally([server("gh", "running"), server("ci", "idle")]), { words: "1 running", stopped: false });
  assert.deepEqual(hostedTally([server("gh", "running"), server("ci", "restarting")]), { words: "1 stopped", stopped: true });
});

test("Connectors: every connector's health, the person's and each folder's, in the words the Mac has (#753)", async () => {
  const { healthTally, healthLine, healthKind, healthLastError, healthTone, personalServers, folderServers, fileProblem } =
    await load("src/model/hostedMCP.ts");
  const snapshot = {
    at: 0,
    problems: [{ folder: "/w/b", message: "mcp.json is not valid JSON. (line 3)" }],
    servers: [
      { name: "github", transport: "http", hosted: false, check: "answered", tools: 3, checkedAt: 0 },
      { name: "local", transport: "stdio", hosted: false, check: "failed", lastError: "The command was not found.", checkedAt: 0 },
      { name: "shared", transport: "stdio", hosted: true, check: "unchecked" },
      { name: "tools", folder: "/w/a", transport: "stdio", hosted: false, check: "waiting" },
    ],
  };
  assert.deepEqual(personalServers(snapshot).map((s) => s.name), ["github", "local", "shared"]);
  assert.deepEqual(folderServers(snapshot, "file:///w/a/").map((s) => s.name), ["tools"], "a folder URL finds the path");
  assert.equal(fileProblem(snapshot, "file:///w/b"), "mcp.json is not valid JSON. (line 3)");
  assert.equal(fileProblem(snapshot), undefined);
  const [github, local, shared, tools] = snapshot.servers;
  assert.match(healthLine(github), /^Answered · 3 tools · checked \d\d:\d\d$/);
  assert.match(healthLine(local), /^Didn't answer · checked /);
  assert.equal(healthLastError(local), "The command was not found.");
  assert.equal(healthLastError(github), undefined);
  assert.equal(healthLine(shared), "Hosted · starts on the first call");
  assert.equal(healthKind(local), "stdio · run in each session");
  assert.equal(healthKind(shared), "stdio · hosted");
  assert.equal(healthLine(tools), "Waiting for approval in this folder's settings, so it is not started");
  assert.equal(healthTone(local), "failing");
  assert.equal(healthTone(shared), "quiet");
  assert.equal(healthTally([]), null);
  assert.deepEqual(healthTally(personalServers(snapshot)), { words: "1 not answering", failing: true });
  assert.deepEqual(healthTally([github, shared]), { words: "2 connectors", failing: false });
});

test("Connectors: each shows its five levels, from what it declares, in the words the Mac has (#1428)", async () => {
  const { connectorLevels, levelsSentence } = await load("src/model/hostedMCP.ts");
  const github = { tools: true, events: true, views: false, workflows: false, tested: false };
  assert.deepEqual(connectorLevels(github).map((l) => l.name), ["Tools", "Events", "Views", "Workflows", "Tested"]);
  assert.deepEqual(connectorLevels(github).filter((l) => l.reached).map((l) => l.name), ["Tools", "Events"]);
  assert.deepEqual(connectorLevels(undefined).filter((l) => l.reached), [], "not checked yet: none reached");
  assert.equal(levelsSentence(github), "Reaches Tools, Events. Not yet Views, Workflows, Tested.");
  assert.equal(levelsSentence(undefined), "Its levels show once its machine has checked it.");
  assert.equal(levelsSentence({ tools: false, events: false, views: false, workflows: false, tested: false }),
    "Reaches none of the five levels yet.");
  assert.equal(levelsSentence({ tools: true, events: true, views: true, workflows: true, tested: true }), "Reaches all five levels.");
});

test("Activity rows: spending added up by currency, headroom, out of the pool", async () => {
  const { todayTotals, totalWords, headroom, closeToFull, dayLimitReached, isOut, lifetimeTotals } = await load("src/views/Activity.tsx");
  const costs = {
    mac: { day: "2026-10-03", today: { USD: 1.5 }, limits: { daily: { amount: 2, currency: "USD" } } },
    box: { day: "2026-10-03", today: { USD: 0.25, GBP: 1 }, limits: {} },
  };
  assert.deepEqual(todayTotals(costs), { USD: 1.75, GBP: 1 });
  assert.match(totalWords(todayTotals(costs)), /1\.00 \+ .*1\.75/);
  assert.equal(totalWords({}), null);
  assert.match(headroom(costs.mac), /0\.50 left$/);
  assert.equal(headroom(costs.box), null, "no limit, nothing left to say");
  assert.equal(closeToFull(costs.mac), false);
  assert.equal(closeToFull({ ...costs.mac, today: { USD: 1.69 } }), false, "80% is not close to full");
  assert.equal(closeToFull({ ...costs.mac, today: { USD: 1.7 } }), true, "85% matches the other clients");
  assert.equal(dayLimitReached({ ...costs.mac, today: { USD: 1.99 } }), false);
  assert.equal(dayLimitReached({ ...costs.mac, today: { USD: 2 } }), true);
  assert.deepEqual(lifetimeTotals([
    { costToDate: { USD: 2, GBP: 1 } }, { costToDate: { USD: 3 } },
  ]), { USD: 5, GBP: 1 });
  const runtime = { id: "codex", name: "Codex" };
  assert.equal(isOut({ runtime, availability: { missing: { lookedIn: [] } } }), false, "never in is not out");
  assert.equal(isOut({ runtime, availability: { available: { path: "/x", supportsResume: true } }, poolNote: "Out until 4pm" }), true);
});

test("Events: where an event is, and everything it carries (#541)", async () => {
  const { eventIsIn, eventDetailRows } = await load("src/views/Activity.tsx");
  const event = (scope, fields = {}) => ({ position: 7, name: "agent.finished", at: 0, count: 1, scope, sentence: "x",
    details: {}, chainDepth: 0, consequences: [], ...fields });
  const inFolder = event({ folder: { _0: "file:///w/api/" } });
  const onMac = event({ mac: {} });
  assert.equal(eventIsIn("all", "mac", inFolder), true);
  assert.equal(eventIsIn("mac", "mac", onMac), true);
  assert.equal(eventIsIn("mac", "mac", inFolder), false);
  assert.equal(eventIsIn("mac|file:///w/api", "mac", inFolder), true, "a trailing slash is the same folder");
  assert.equal(eventIsIn("box|file:///w/api", "mac", inFolder), false, "the same folder on another host is apart");
  assert.equal(eventIsIn("mac|file:///w/api", "mac", onMac), false);
  const rows = eventDetailRows(event({ mac: {} }, {
    count: 3, lastAt: 60_000, publisher: { agentID: "a", title: "Fix it" }, message: "done", details: { b: "2", a: "1" },
  }), "This Mac");
  assert.deepEqual(rows.map(([name]) => name), ["When", "Where", "Repeats", "Published by", "Message", "a", "b", "Position"]);
  assert.equal(rows[1][1], "This Mac");
  assert.match(rows[2][1], /^3 times, last at \d\d:\d\d$/);
  assert.equal(rows.at(-1)[1], "7");
  assert.deepEqual(eventDetailRows(onMac, "This Mac").map(([name]) => name), ["When", "Where", "Position"]);
  const byAna = eventDetailRows(event({ mac: {} }, { actor: { user: "ana", userName: "Ana", clientName: "Ana's iPhone" } }), "This Mac");
  assert.deepEqual(byAna[2], ["By", "Ana · Ana's iPhone"], "a person's call names them (#1751)");
});

test("Archived folders: every host's, the latest worked on first, apart from the live ones (#343)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { archivedFolders } = await load("src/views/Sidebar.tsx");
    const folder = (name, lastActivityAt, archivedAt) => ({ name, lastActivityAt,
      folder: { folder: `file:///w/${name}/`, addedAt: 0, ...(archivedAt === undefined ? {} : { archivedAt }) } });
    const hosts = [{ id: "mac", name: "This Mac" }, { id: "box", name: "box" }];
    const shown = archivedFolders(hosts, {
      mac: [folder("live", 50), folder("old", 10, 20)],
      box: [folder("newer", 30, 40)],
    });
    assert.deepEqual(shown.map(({ host, folder }) => `${host.id}:${folder.name}`), ["box:newer", "mac:old"]);
    assert.deepEqual(archivedFolders(hosts, { mac: [folder("live", 50)] }), [], "none archived, no fold");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Folders: this Mac's then each server's, oldest added first, however busy (#357)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { orderedFolders } = await load("src/views/Sidebar.tsx");
    const folder = (name, addedAt, lastActivityAt = 0, archivedAt) => ({ name, lastActivityAt,
      folder: { folder: `file:///w/${name}/`, addedAt, ...(archivedAt === undefined ? {} : { archivedAt }) } });
    const hosts = [{ id: "box", name: "box" }, { id: "mac", name: "This Mac" }];
    const names = (folders) => orderedFolders(hosts, folders).map(({ host, folder }) => `${host.id}:${folder.name}`);
    const listed = { mac: [folder("busy", 20, 999), folder("first", 10), folder("gone", 5, 0, 30)],
                     box: [folder("api", 1)] };
    assert.deepEqual(names(listed), ["mac:first", "mac:busy", "box:api"], "activity does not move a row");
    listed.mac.push(folder("new", 40));
    assert.deepEqual(names(listed), ["mac:first", "mac:busy", "mac:new", "box:api"], "a new folder lands at the end");
    assert.deepEqual(names({ mac: [folder("b", 10), folder("a", 10)] }), ["mac:a", "mac:b"], "same moment: by folder");
    const pinned = (p) => ({ ...p, folder: { ...p.folder, pinned: true } });
    assert.deepEqual(names({ mac: [folder("a", 1), pinned(folder("chat", 2))], box: [pinned(folder("api", 3))] }),
      ["mac:chat", "box:api", "mac:a"], "the pinned first, from every host");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Status and Usage are open until folded, and Archived folders closed until opened (#915, #343)", async () => {
  const m = await load("test/preferences-entry.ts");
  const sent = [];
  m.sendPreferencesWith((changes) => sent.push(changes));
  const folds = new m.Folds(new Memory());
  assert.equal(folds.showsStatus.value, true, "open by default");
  assert.equal(folds.showsUsage.value, true, "open by default");
  assert.equal(folds.showsArchivedFolders.value, false, "closed by default");
  folds.setShowsStatus(false);
  folds.setShowsArchivedFolders(true);
  assert.equal(folds.showsStatus.value, false);
  assert.equal(folds.showsUsage.value, true, "folding Status leaves Usage open");
  assert.equal(folds.showsArchivedFolders.value, true);
  assert.deepEqual(sent, [{ showsActivity: false }, { showsArchivedFolders: true }], "sent to the Mac, by the window's names");
  folds.setShowsStatus(false);
  assert.equal(sent.length, 2, "no change, nothing sent");
});

test("the sidebar follows what the Mac says (#1033)", async () => {
  const m = await load("test/preferences-entry.ts");
  const folds = new m.Folds(new Memory());
  m.preferencesSaid({ showsActivity: false, showsUsage: false, showsArchivedFolders: true, sidebarSmartGroupsOff: "" });
  assert.equal(folds.showsStatus.value, false);
  assert.equal(folds.showsUsage.value, false);
  assert.equal(folds.showsArchivedFolders.value, true);
  assert.equal(m.smartGroupsOn.value.size, 4, "every group on is a choice too");
  m.preferencesSaid({});
  assert.equal(folds.showsStatus.value, true, "nothing said is the default");
  assert.equal(m.smartGroupsOn.value.has("working"), false, "Working is off at first (#979)");
});

test("a tab holding one folder alone keeps it in every address in it, until ‹ All (#1089)", async () => {
  globalThis.location = { hash: "#/o/1/h/mac/p/file%3A%2F%2F%2Fw%2Fa/n/1", pathname: "/", search: "" };
  globalThis.addEventListener = () => {};
  const went = [];
  try {
    const { alone, aloneURL, parseRoute, route, routeHash, showAll } = await load("src/route.ts");
    assert.deepEqual(parseRoute(location.hash), { alone: true, host: "mac", folder: "file:///w/a", compose: true });
    assert.deepEqual(alone.value, { host: "mac", folder: "file:///w/a" }, "opened alone, it holds the folder");
    assert.equal(route.value.compose, true);
    assert.equal(routeHash({ host: "mac", folder: "file:///w/a/", session: "s" }),
      "#/o/1/h/mac/p/file%3A%2F%2F%2Fw%2Fa%2F/s/s", "a session in it stays alone");
    assert.equal(routeHash({ host: "mac", folder: "file:///w/b", session: "t" }),
      "#/h/mac/p/file%3A%2F%2F%2Fw%2Fb/s/t", "another folder's is not");
    assert.equal(aloneURL("box", "file:///w/c"), "/#/o/1/h/box/p/file%3A%2F%2F%2Fw%2Fc/n/1", "Open in New Tab");
    Object.defineProperty(globalThis.location, "hash", { get: () => "", set: (h) => went.push(h), configurable: true });
    showAll();
    assert.equal(alone.value, undefined);
    assert.deepEqual(went, ["#/h/mac/p/file%3A%2F%2F%2Fw%2Fa"], "‹ All goes to the folder among every folder");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("a tab holding one folder is titled with its name (#1089)", async () => {
  const { titleFor } = await load("src/presence.ts");
  assert.equal(titleFor(0), "Agents");
  assert.equal(titleFor(2, "alpha"), "(2) alpha");
});

test("Remove…'s words name a server and say a refusal as a removal (#2266)", async () => {
  const { removesWords, notRemoved, notRemovedOffline } = await load("src/model/hostedMCP.ts");
  assert.equal(removesWords("github", true, "devbox"),
    "This removes the github entry from .agents/mcp.json on devbox. Agents started after that won't have it.");
  assert.equal(removesWords("github", false), "This removes the github entry from ~/.agents/mcp.json. Agents started after that won't have it. A copy of the entry is kept in ~/.agents/mcp.removed.json.");
  assert.equal(notRemovedOffline("github", "devbox"), "github was not removed: devbox is offline.");
  assert.equal(notRemoved("github", "That machine is offline."), "github was not removed. That machine is offline.");
});
