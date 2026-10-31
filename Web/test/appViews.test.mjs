// Views drawn from ui:// resources (#187, MCP Apps): the web page's half of the conversation, the
// policy its sandbox proxy draws under (the same strings as AppViewPolicy in Swift), and the fold.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const bridge = await load("src/views/chat/appViewBridge.ts");
const policy = await load("src/sandbox/policy.ts");
const turns = await load("src/model/turns.ts");

const ask = (method, params = {}, id = 1) => bridge.read({ jsonrpc: "2.0", method, params, ...(id === null ? {} : { id }) });

test("the bridge reads what a view asks", () => {
  assert.deepEqual(ask("ui/initialize"), { kind: "initialize", id: 1 });
  assert.deepEqual(ask("ui/notifications/initialized", {}, null), { kind: "initialized" });
  assert.deepEqual(ask("tools/call", { name: "test_view_count", arguments: { by: 1 } }),
    { kind: "callTool", id: 1, name: "test_view_count", arguments: { by: 1 } });
  assert.equal(ask("tools/call", {}).kind, "malformed");
  assert.deepEqual(ask("resources/read", { uri: "ui://agents/test-view" }), { kind: "readResource", id: 1, uri: "ui://agents/test-view" });
  assert.equal(ask("ui/open-link", { url: "https://example.com/" }).kind, "openLink");
  assert.equal(ask("ui/open-link", { url: "javascript:alert(1)" }).kind, "malformed");
  assert.equal(ask("ui/open-link", { url: "file:///etc/passwd" }).kind, "malformed");
  assert.deepEqual(ask("ui/message", { role: "user", content: { type: "text", text: " Hi " } }), { kind: "message", id: 1, text: "Hi" });
  assert.deepEqual(ask("ui/message", { role: "user", content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] }),
    { kind: "message", id: 1, text: "a\nb" });
  assert.deepEqual(ask("ui/request-display-mode", { mode: "fullscreen" }), { kind: "displayMode", id: 1, mode: "fullscreen" });
  assert.deepEqual(ask("ui/notifications/size-changed", { width: 300, height: 120.5 }, null), { kind: "sizeChanged", width: 300, height: 120.5 });
  assert.deepEqual(ask("notifications/message", { level: "info", data: "x" }, null), { kind: "log", level: "info", data: "x" });
  assert.deepEqual(ask("sampling/createMessage"), { kind: "unknown", id: 1, method: "sampling/createMessage" });
  assert.deepEqual(bridge.read({ jsonrpc: "2.0", id: "teardown-1", result: {} }), { kind: "answered", id: "teardown-1" });
  assert.deepEqual(bridge.read({ method: "ui/initialize", id: 1 }), { kind: "ignored" });
  assert.deepEqual(bridge.read("not an object"), { kind: "ignored" });
});

test("agents/message-agent is read as AppViewAgentMessage reads it (#837)", () => {
  assert.deepEqual(ask("agents/message-agent", { branch: " agents/fix-837 ", text: " Fix it \n" }),
    { kind: "messageAgent", id: 1, message: { branch: "agents/fix-837", text: "Fix it" } });
  const refused = (params) => ask("agents/message-agent", params);
  assert.deepEqual(refused({ text: "Fix" }), { kind: "malformed", id: 1, reason: "agents/message-agent needs a branch." });
  assert.deepEqual(refused({ branch: "b", text: " " }), { kind: "malformed", id: 1, reason: "agents/message-agent needs text." });
  assert.equal(refused({ branch: "b", text: "x".repeat(8001) }).kind, "malformed");
  assert.equal(refused({ branch: "b".repeat(256), text: "Fix" }).kind, "malformed");
  // A start may name a branch for its worktree (#837).
  assert.deepEqual(ask("agents/start-agent", { prompt: "Fix PR #9", labels: ["P#9"], branch: " agents/fix-9 " }),
    { kind: "startAgent", id: 1, start: { prompt: "Fix PR #9", labels: ["P#9"], branch: "agents/fix-9" } });
});

test("the message goes to the latest session on the branch, in the folder (#837)", () => {
  const agent = (title, branch, lastActivityAt, more = {}) => ({ id: title, title, cwd: "/tmp/repo/.agents/worktrees/w", lastActivityAt,
    worktree: { name: "fix-837", root: "/tmp/repo/.agents/worktrees/w", branch, folder: "/tmp/repo" }, ...more });
  const agents = [agent("Older", "agents/fix-837", 10), agent("Newer", "agents/fix-837", 20),
    agent("Archived", "agents/fix-837", 30, { archivedAt: 1 }), agent("Other branch", "agents/fix-838", 40),
    agent("Other folder", "agents/fix-837", 50, { worktree: { name: "x", root: "/tmp/other/x", branch: "agents/fix-837", folder: "/tmp/other" } })];
  const message = { branch: "agents/fix-837", text: "Fix" };
  assert.deepEqual(bridge.recipient(agents, message, "/tmp/repo/"), { id: "Newer", name: "Newer" });
  assert.equal(bridge.recipient(agents.slice(2), message, "/tmp/repo"), null);
  assert.deepEqual(bridge.recipient([agent("", "agents/fix-837", 1)], message, "/tmp/repo"), { id: "", name: "fix-837" });
});

test("agents/start-agent is read as AppViewStart reads it (#834)", () => {
  assert.deepEqual(ask("agents/start-agent", { prompt: "  Fix #834 \n", labels: [" #834 ", "#834", "ci"], worktree: " fix-834 " }),
    { kind: "startAgent", id: 1, start: { prompt: "Fix #834", labels: ["#834", "ci"], worktree: "fix-834" } });
  // Labels and worktree are optional; an empty worktree leaves the form's place.
  assert.deepEqual(ask("agents/start-agent", { prompt: "Go", worktree: "  " }), { kind: "startAgent", id: 1, start: { prompt: "Go", labels: [] } });
  const refused = (params) => ask("agents/start-agent", params);
  assert.deepEqual(refused({}), { kind: "malformed", id: 1, reason: "agents/start-agent needs a prompt." });
  assert.deepEqual(refused({ prompt: "   " }), { kind: "malformed", id: 1, reason: "agents/start-agent needs a prompt." });
  assert.deepEqual(refused({ prompt: 3 }), { kind: "malformed", id: 1, reason: "agents/start-agent needs a prompt." });
  assert.equal(refused({ prompt: "x".repeat(8001) }).reason, "The prompt is longer than 8000 characters.");
  assert.equal(ask("agents/start-agent", { prompt: "x".repeat(8000) }).kind, "startAgent");
  // Counted in characters as Swift counts them: a flag is one, not four UTF-16 units.
  assert.equal(ask("agents/start-agent", { prompt: "🇬🇧".repeat(8000) }).kind, "startAgent");
  assert.equal(refused({ prompt: "Go", labels: [" "] }).reason, "Each label is text of 1 to 24 characters.");
  assert.equal(refused({ prompt: "Go", labels: ["x".repeat(25)] }).reason, "Each label is text of 1 to 24 characters.");
  assert.equal(refused({ prompt: "Go", labels: [7] }).reason, "Each label is text of 1 to 24 characters.");
  assert.equal(refused({ prompt: "Go", labels: Array.from({ length: 6 }, (_, i) => `l${i}`) }).reason, "A session can have at most five labels.");
  // Repeats are counted once, whatever their case, so six with a repeat are five.
  assert.equal(ask("agents/start-agent", { prompt: "Go", labels: [...Array.from({ length: 5 }, (_, i) => `l${i}`), "L0"] }).start.labels.length, 5);
  assert.equal(ask("agents/start-agent", { prompt: "Go", worktree: "w".repeat(150) }).start.worktree, "w".repeat(100));
});

const context = {
  theme: "dark", displayMode: "inline", width: 640, maxHeight: 640, locale: "en-GB", timeZone: "Europe/London",
  touch: false, hover: true, variables: { "--color-background-primary": "light-dark(#fbf9f4, #1c1b19)" }, tool: "show_test_view",
};

test("the initialize answer carries the host context, as the Mac's does", () => {
  const strict = { connectDomains: [], resourceDomains: [], frameDomains: [], baseUriDomains: [], refused: [] };
  const result = bridge.initializeResult(context, strict);
  assert.equal(result.protocolVersion, "2026-01-26");
  assert.equal(result.hostContext.platform, "web");
  assert.equal(result.hostContext.theme, "dark");
  assert.deepEqual(result.hostContext.containerDimensions, { width: 640, maxHeight: 640 });
  assert.deepEqual(result.hostContext.availableDisplayModes, ["inline", "fullscreen"]);
  assert.equal(result.hostContext.styles.variables["--color-background-primary"], "light-dark(#fbf9f4, #1c1b19)");
  assert.deepEqual(result.hostCapabilities.sandbox.csp, {});
  // A whole MCP Tool: the ext-apps SDK refuses ui/initialize without an inputSchema (#191).
  assert.deepEqual(result.hostContext.toolInfo, { tool: { name: "show_test_view", inputSchema: { type: "object" } } });
});

test("only what changed is said again", () => {
  assert.equal(bridge.contextChanges(context, context), null);
  assert.deepEqual(bridge.contextChanges({ ...context, theme: "light" }, context), { theme: "light" });
  const full = { ...context, displayMode: "fullscreen", height: 700, maxHeight: undefined };
  assert.deepEqual(bridge.contextChanges(full, context), { displayMode: "fullscreen", containerDimensions: { width: 640, height: 700 } });
});

test("the feed says each thing once and in order", () => {
  const call = { id: "A", server: "agents", tool: "show_test_view", resourceUri: "ui://agents/test-view", arguments: { note: "x" }, state: "running" };
  const feed = new bridge.Feed();
  assert.deepEqual(feed.due(call), []);
  assert.deepEqual(feed.viewInitialized(call).map((m) => m.method), ["ui/notifications/tool-input"]);
  assert.deepEqual(feed.due(call), []);
  const done = { ...call, state: "done", result: { content: [], structuredContent: { a: 1 } } };
  const sent = feed.due(done);
  assert.deepEqual(sent.map((m) => m.method), ["ui/notifications/tool-result"]);
  assert.deepEqual(sent[0].params.structuredContent, { a: 1 });
  assert.deepEqual(feed.due(done), []);
  const again = { ...done, result: { content: [], structuredContent: { a: 2 } } };
  const resent = feed.due(again);
  assert.deepEqual(resent.map((m) => m.method), ["ui/notifications/tool-result"]);
  assert.deepEqual(resent[0].params.structuredContent, { a: 2 });
  assert.deepEqual(feed.due(again), []);
  const late = new bridge.Feed();
  assert.deepEqual(late.viewInitialized({ ...call, state: "cancelled", reason: "Stopped." }).map((m) => m.method),
    ["ui/notifications/tool-input", "ui/notifications/tool-cancelled"]);
});

// The same strings AgentsKitCore's AppViewPolicy.header writes (AppViewTests in Swift).
const strictHeader = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
  + "img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; frame-src 'none'; "
  + "object-src 'none'; base-uri 'self'; form-action 'none'";

test("the proxy's policy is the Mac's, strict by default and never wider than an origin", () => {
  assert.equal(policy.header(undefined), strictHeader);
  const declared = policy.header({ connectDomains: ["https://api.example.com", "*", "https:"], resourceDomains: ["https://*.cdn.example.net"],
    frameDomains: ["https://www.youtube.com"] });
  assert.match(declared, /connect-src https:\/\/api\.example\.com;/);
  assert.match(declared, /script-src 'self' 'unsafe-inline' https:\/\/\*\.cdn\.example\.net;/);
  assert.match(declared, /frame-src https:\/\/www\.youtube\.com;/);
  for (const bad of ["*", "https:", "'unsafe-eval'", "https://a.com; script-src *", "https://*", "javascript:alert(1)",
    "https://a.com:99999", "https://-bad.com", "ftp://a.com", "https://a.com/path"]) {
    assert.equal(policy.origin(bad), null, bad);
  }
  assert.equal(policy.origin("WSS://Live.Example.com:8443/"), "wss://live.example.com:8443");
});

test("the view's own head has the policy first", () => {
  assert.ok(policy.withPolicy("<p>bare</p>", "x").startsWith("<head><meta http-equiv=\"Content-Security-Policy\" content=\"x\">"));
  assert.ok(policy.withPolicy("<html lang=en><head><title>t</title>", "a&\"b")
    .startsWith("<html lang=en><head><meta http-equiv=\"Content-Security-Policy\" content=\"a&amp;&quot;b\"><title>"));
});

test("the proxy's address carries the domains as base64url JSON", () => {
  const encoded = policy.encodeDomains({ connectDomains: ["https://api.example.com"] });
  assert.match(encoded, /^[A-Za-z0-9_-]+$/);
  const json = JSON.parse(Buffer.from(encoded.replaceAll("-", "+").replaceAll("_", "/"), "base64").toString());
  assert.deepEqual(json.connectDomains, ["https://api.example.com"]);
});

test("a view is drawn once, where its call began, with its latest state, at every level", () => {
  const view = (state, extra = {}) => ({ appView: { _0: { id: "V", server: "agents", tool: "show_test_view",
    resourceUri: "ui://agents/test-view", state, ...extra } } });
  const items = turns.display([
    { id: "1", at: 0, kind: { agentMessage: { messageID: "m", text: "Here it is." } } },
    { id: "2", at: 1, kind: view("running") },
    { id: "3", at: 2, kind: { agentMessage: { messageID: "n", text: "Done." } } },
    { id: "4", at: 3, kind: view("done", { result: { content: [] } }) },
  ]);
  assert.equal(items.length, 3);
  assert.equal(items[1].id, "2");
  assert.equal(items[1].entry.kind.appView._0.state, "done");
  assert.ok(turns.isOutcome(items[1]));
});

// Pins (#189): Pin is offered for a call the host says can feed one, once it has answered, and a
// pinned view's page makes its own call, as the host's, then hands the view its answer.
test("Pin is offered only for a pinnable call that has answered", () => {
  const call = { id: "A", server: "agents", tool: "show_test_view", resourceUri: "ui://agents/test-view", arguments: { note: "x" }, state: "done" };
  assert.equal(bridge.canPin({ ...call, pinnable: true }), true);
  assert.equal(bridge.canPin(call), false);
  assert.equal(bridge.canPin({ ...call, pinnable: false }), false);
  assert.equal(bridge.canPin({ ...call, pinnable: true, state: "running" }), false);
  assert.equal(bridge.canPin({ ...call, pinnable: true, state: "cancelled" }), false);
  assert.deepEqual(bridge.viewPin(call), { server: "agents", uri: "ui://agents/test-view", tool: "show_test_view", arguments: { note: "x" } });
  assert.deepEqual(bridge.viewPin({ ...call, arguments: undefined }), { server: "agents", uri: "ui://agents/test-view", tool: "show_test_view" });
});

test("a pinned view is fed by the host's own call: input first, then its answer", () => {
  const view = { server: "agents", uri: "ui://agents/test-view", tool: "show_test_view", arguments: { note: "pinned" } };
  assert.deepEqual(bridge.feedParams("P", "file:///p", view),
    { agentID: "P", viewID: "P", name: "show_test_view", folder: "file:///p", feed: true, arguments: { note: "pinned" } });
  const running = bridge.pinnedViewCall("P", view);
  assert.deepEqual(running, { id: "P", server: "agents", tool: "show_test_view", resourceUri: "ui://agents/test-view",
    arguments: { note: "pinned" }, state: "running" });
  const answer = { content: [{ type: "text", text: "Shown." }] };
  const done = bridge.pinnedViewCall("P", view, answer);
  assert.equal(done.state, "done");
  assert.deepEqual(done.result, answer);
  const feed = new bridge.Feed();
  assert.deepEqual(feed.viewInitialized(running).map((m) => m.method), ["ui/notifications/tool-input"]);
  assert.deepEqual(feed.due(done), [{ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: answer }]);
});

test("a person's own server's view names its server, and asks Show first (#191)", () => {
  assert.equal(bridge.viewTitle("weather", "kite"), "weather · kite");
  assert.equal(bridge.viewTitle("show_test_view", "agents"), "Test view");
  assert.deepEqual(bridge.serverParam("agents"), {});
  assert.deepEqual(bridge.serverParam("kite"), { server: "kite" });
  assert.deepEqual(bridge.needsShow(-32063, { server: "kite", uri: "ui://kite/w", hash: "h", isNew: false }),
    { server: "kite", uri: "ui://kite/w", hash: "h", isNew: false });
  assert.equal(bridge.needsShow(-32062, { server: "kite", uri: "u", hash: "h" }), null);
  assert.equal(bridge.needsShow(-32063, { server: "kite" }), null);
  const view = { server: "kite", uri: "ui://kite/w", tool: "weather" };
  assert.equal(bridge.feedParams("P", "/p", view).server, "kite");
  assert.equal(bridge.feedParams("P", "/p", { ...view, server: "agents" }).server, undefined);
});

// agents/open-diff (#1341): a pull request's files, as hunks, for the page's own diff.
test("the bridge reads a diff to draw, and refuses one that is not", () => {
  const files = [{ path: "average.py", change: "modified", additions: 1, deletions: 1,
    hunks: [{ oldStart: 4, newStart: 4, lines: [{ kind: "context", text: "a" }, { kind: "removed", text: "b" }, { kind: "added", text: "c" }] }] },
  { path: "logo.png", change: "added", additions: 0, deletions: 0, hunks: [], note: "No lines to show." }];
  const read = ask("agents/open-diff", { title: "#1 Fix", url: "https://github.com/o/r/pull/1/files", files, path: "logo.png" });
  assert.equal(read.kind, "openDiff");
  assert.equal(read.diff.title, "#1 Fix");
  assert.equal(read.diff.url, "https://github.com/o/r/pull/1/files");
  assert.equal(read.diff.path, "logo.png");
  assert.equal(read.diff.cut, false);
  assert.deepEqual(read.diff.files[0].hunks, files[0].hunks);
  assert.equal(read.diff.files[1].note, "No lines to show.");
  assert.equal(ask("agents/open-diff", { title: "x" }).kind, "malformed");
  assert.equal(ask("agents/open-diff", { files: [{ hunks: [] }] }).kind, "malformed");
  assert.equal(ask("agents/open-diff", { files: [{ path: "a", hunks: [{ lines: [{ kind: "moved", text: "x" }] }] }] }).kind, "malformed");
  assert.equal(ask("agents/open-diff", { files, url: "javascript:alert(1)" }).diff.url, undefined);
  const many = [{ path: "big", hunks: [{ oldStart: 1, newStart: 1, lines: Array.from({ length: bridge.diffLineLimit + 1 }, () => ({ kind: "added", text: "" })) }] }];
  assert.equal(ask("agents/open-diff", { files: many }).kind, "malformed");
});
