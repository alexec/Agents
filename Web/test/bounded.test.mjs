// One event redraws what it changed, and the page holds a bounded amount (#170).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const {
  Work, Store, archivedPage, searchShown, keepingTurns, effect,
  turnPage, openTurnsHeld, historyEntriesCap, historyTurnsCap, rememberOpen, quietSettle,
} = await load("test/bounded.ts");
const w = await load("test/wire.ts");

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function agent(id, project, at, extra = {}) {
  return {
    id, title: `Session ${id}`, cwd: `file:///w/${project}/`, createdAt: at, lastActivityAt: at, runtimeID: "claude",
    state: "finished", advertisedOptions: [], availableCommands: [], startOptions: { extraArguments: [], values: {} }, ...extra,
  };
}

/** How often an effect reading `read` runs again after its first run. */
function runs(read) {
  let count = -1;
  const stop = effect(() => { read(); count++; });
  return { get count() { return count; }, stop };
}

test("one agent's change redraws its own project and no other", () => {
  const work = new Work();
  const listed = [];
  for (let p = 0; p < 5; p++) for (let i = 0; i < 20; i++) listed.push(agent(`${p}-${i}`, `p${p}`, p * 100 + i));
  work.replaceAgents(listed, "mac");
  const views = [0, 1, 2, 3, 4].map((p) => runs(() => work.projectView("mac", `file:///w/p${p}`)));
  const before = work.projectView("mac", "file:///w/p1");
  work.apply("agent/changed", { ...listed[25], isUnread: true, lastActivityAt: 10_000 }, "mac");
  assert.deepEqual(views.map((v) => v.count), [0, 1, 0, 0, 0], "only p1 was worked out again");
  assert.notEqual(work.projectView("mac", "file:///w/p1"), before);
  assert.equal(work.projectView("mac", "file:///w/p1").subtitle, "1 unread");
  assert.equal(work.agents.value.mac[0].id, "1-5", "newest first");
  // Moving to another project tells both.
  work.apply("agent/changed", { ...listed[25], cwd: "file:///w/p3/", lastActivityAt: 10_001 }, "mac");
  assert.deepEqual(views.map((v) => v.count), [0, 2, 0, 1, 0]);
  assert.equal(work.projectAgents("mac", "file:///w/p3").length, 21);
  // A whole list again tells only the projects whose agents differ.
  work.replaceAgents(work.agents.value.mac, "mac");
  assert.deepEqual(views.map((v) => v.count), [1, 3, 1, 2, 1], "keepingLists makes every record anew");
  work.apply("agent/removed", { agentID: "4-0" }, "mac");
  assert.deepEqual(views.map((v) => v.count), [1, 3, 1, 2, 2]);
  for (const v of views) v.stop();
});

test("upsert puts an agent where a stable sort would", () => {
  const work = new Work();
  work.replaceAgents([agent("a", "p", 5), agent("b", "p", 3), agent("c", "p", 1)], "mac");
  work.apply("agent/changed", agent("d", "p", 3), "mac");
  work.apply("agent/changed", agent("c", "p", 9), "mac");
  assert.deepEqual(work.agents.value.mac.map((a) => a.id), ["c", "a", "b", "d"]);
});

test("the open agent is read without being redrawn by its neighbours", () => {
  const work = new Work();
  work.replaceAgents([agent("a", "p", 1), agent("b", "p", 2)], "mac");
  const reads = runs(() => work.agent("mac", "a"));
  work.apply("agent/changed", agent("b", "p", 3), "mac");
  assert.equal(reads.count, 0);
  work.apply("agent/changed", agent("a", "p", 4), "mac");
  assert.equal(reads.count, 1);
  reads.stop();
});

test("an Archived fold closed lets its sessions go, the open one kept", () => {
  const work = new Work();
  work.replaceAgents([agent("live", "p", 9)], "mac");
  work.addAgents([agent("old1", "p", 1, { state: "archived" }), agent("old2", "p", 2, { state: "archived" }),
    agent("other", "q", 3, { state: "archived" })], "mac");
  work.watch("mac", "old2");
  work.dropArchived("mac", "file:///w/p");
  assert.deepEqual(work.agents.value.mac.map((a) => a.id), ["live", "other", "old2"]);
});

function entry(n, kind) {
  return { id: `e${n}`, at: n, kind };
}

function said(n) {
  return entry(n, { agentMessage: { text: `line ${n}`, messageID: `m${n}` } });
}

function asked(n) {
  return entry(n, { userMessage: { text: `ask ${n}`, from: "person" } });
}

test("an entry keeps every turn it did not land in the same object", () => {
  const work = new Work();
  work.watch("mac", "s");
  work.replaceTranscript({ entries: [asked(1), said(2), asked(3), said(4)], firstIndex: 0 });
  const [first, second] = work.chatTurns.value;
  work.apply("agent/entry", { agentID: "s", entry: said(5) }, "mac");
  const after = work.chatTurns.value;
  assert.equal(after[0], first, "the earlier turn is the same object");
  assert.notEqual(after[1], second, "the turn it landed in is new");
  assert.deepEqual(keepingTurns(after, after), after);
});

test("reconnect turns keep one latest copy and one row across stored and live turns", () => {
  const work = new Work();
  const summary = (id, steps) => ({ id, start: 0, end: 2, steps });
  work.replaceTurns({ turns: [summary("t-old", 1), summary("t-later", 1)], firstTurn: 1, openStart: 4 });
  work.prependTurns({ turns: [summary("t-first", 1), summary("t-old", 2), summary("t-old", 3)], firstTurn: 0 });
  assert.deepEqual(work.turns.value.map((turn) => turn.id), ["t-first", "t-old", "t-later"]);
  assert.equal(work.turns.value[1].steps, 1, "the already-held copy is newer than the earlier page");

  work.replaceTurns({ turns: [summary("e1", 1)], firstTurn: 0, openStart: 0 });
  work.replaceTranscript({ entries: [asked(1), said(2)], firstIndex: 0 });
  assert.equal(work.chatTurns.value.filter((turn) => turn.id === "e1").length, 1);
  assert.equal(work.chatTurns.value[0].items.length, 1, "the live copy carries its current entries");
});

test("a repeated catch-up entry updates the held entry and the incoming page copy", () => {
  const work = new Work();
  work.watch("mac", "s");
  const original = { ...said(1), id: "same" };
  const updated = { ...original, kind: { agentMessage: { text: "newer", messageID: "m1" } } };
  work.apply("agent/entry", { agentID: "s", entry: original }, "mac");
  work.apply("agent/entry", { agentID: "s", entry: updated }, "mac");
  work.replaceTranscript({ entries: [original], firstIndex: 0 });
  assert.deepEqual(work.entries.value.map((entry) => entry.id), ["same"]);
  assert.equal(work.entries.value[0].kind.agentMessage.text, "newer");
});

test("a followed chat is trimmed at the front, and one scrolled up is not", () => {
  const work = new Work();
  work.watch("mac", "s");
  work.replaceTranscript({ entries: [], firstIndex: 0 });
  let n = 0;
  const feed = (count) => { for (let i = 0; i < count; i++, n++) work.apply("agent/entry", { agentID: "s", entry: n % 4 === 0 ? asked(n) : said(n) }, "mac"); };
  work.setFollowingEnd(false);
  feed(900);
  assert.equal(work.entries.value.length, 900, "nothing goes from under a reader");
  work.setFollowingEnd(true);
  feed(1);
  assert.ok(work.entries.value.length <= 600, `trimmed to ${work.entries.value.length}`);
  assert.equal(work.firstEntryIndex.value + work.entries.value.length, 901, "where it starts is counted");
  assert.equal(work.hasMoreBefore.value, true);
  assert.equal(work.items.value[0].id, work.entries.value[0].id, "cut where a row begins");
  feed(2000);
  assert.ok(work.entries.value.length <= 800, `held ${work.entries.value.length}`);
});

test("back at the end, the finished turns above are let go to the last hundred", () => {
  const work = new Work();
  work.watch("mac", "s");
  const summary = (i) => ({ id: `t${i}`, start: i * 2, end: i * 2 + 2 });
  work.replaceTurns({ turns: [190, 191].map(summary), firstTurn: 190, openStart: 384 });
  work.setFollowingEnd(false);
  for (let page = 189; page > 0; page -= 50) {
    work.prependTurns({ turns: Array.from({ length: 50 }, (_, i) => summary(page - 49 + i)).filter((t) => +t.id.slice(1) >= 0), firstTurn: Math.max(0, page - 49) });
  }
  assert.ok(work.turns.value.length > 150);
  work.setFollowingEnd(true);
  assert.equal(work.turns.value.length, 100);
  assert.equal(work.firstTurn.value, 92);
  assert.equal(work.turns.value[0].id, "t92");
});

/** A link that answers from `replies` and counts what it was asked, by host and method. */
function fakeLink(replies) {
  const asked = [];
  let notify = () => {};
  return {
    asked,
    notify: (method, params, host = null) => notify(method, params, host),
    onNotification: (listener) => { notify = listener; },
    onState: () => {},
    call: async (method, params, host) => {
      asked.push(`${host ?? "control"} ${method}`);
      const reply = replies(method, params, host);
      if (reply === undefined) throw new Error("no");
      return reply;
    },
  };
}

test("hostChanged loads the host it names, once however often it is said, and no other", async () => {
  const hosts = [{ id: "mac", state: "online" }, { id: "box", state: "online" }];
  const link = fakeLink((method) => (method === "hosts/list" ? hosts : method === "agents/list" ? [] : method.endsWith("/pending") ? [] : undefined));
  const store = new Store(link);
  link.notify("control/hostChanged", { host: "box", state: "online" });
  link.notify("control/hostChanged", { host: "box", state: "online" });
  await wait(300);
  await wait(10);
  const lists = link.asked.filter((line) => line.endsWith("agents/list"));
  assert.deepEqual(lists, ["box agents/list"]);
  // One going offline loads nothing; one removed is forgotten.
  link.asked.length = 0;
  store.agents.value = { ...store.agents.value, box: [agent("x", "p", 1)] };
  hosts.pop();
  link.notify("control/hostChanged", { host: "box", state: "removed" });
  await wait(300);
  assert.deepEqual(link.asked, ["control hosts/list"]);
  assert.equal(store.agents.value.box, undefined);
});

test("an Archived fold asks for a page, and a reconnect lists it again rather than emptying it", async () => {
  const hosts = [{ id: "mac", state: "online" }];
  const params = [];
  const link = fakeLink((method, p) => {
    if (method === "hosts/list") return hosts;
    if (method === "agents/list") { params.push(p); return p.archivedOnly ? [agent("old", "p", 1, { state: "archived" })] : [agent("live", "p", 2)]; }
    if (method.endsWith("/pending")) return [];
    return undefined;
  });
  const store = new Store(link);
  await store.loadArchived("mac", "file:///w/p");
  assert.equal(params[0].limit, archivedPage);
  await store.load();
  await wait(10);
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["live", "old"]);
});

test("a call that is never answered is given up", async () => {
  const sockets = [];
  const l = new w.Link({ url: "ws://localhost:1/v1/connect", origin: "http://localhost:1",
    keys: Object.assign(new w.MemoryKeyStore(), { record: { privateKey: {}, publicKey: {}, client: "C", control: "K", paired: "" } }),
    open: () => {
      const socket = { sent: [], send(line) { this.sent.push(line); }, close() {}, onopen: null, onmessage: null, onclose: null, onerror: null };
      sockets.push(socket);
      setTimeout(() => socket.onopen?.({}), 0);
      return socket;
    },
    backoff: [0.01], heartbeat: { every: 60_000, within: 1_000 }, random: () => 0, callTimeout: 20,
    authenticate: async () => ({ name: "test" }) });
  l.start();
  await wait(5);
  await assert.rejects(l.call("hosts/list", {}), (error) => error instanceof w.CallTimedOut);
  l.stop();
});

test("out of sight, a dropped link waits for the tab to come back", async () => {
  const sockets = [];
  let hidden = false;
  const l = new w.Link({ url: "ws://localhost:1/v1/connect", origin: "http://localhost:1",
    keys: Object.assign(new w.MemoryKeyStore(), { record: { privateKey: {}, publicKey: {}, client: "C", control: "K", paired: "" } }),
    open: () => {
      const socket = { send() {}, close() {}, onopen: null, onmessage: null, onclose: null, onerror: null };
      sockets.push(socket);
      setTimeout(() => socket.onopen?.({}), 0);
      return socket;
    },
    backoff: [0.001], heartbeat: { every: 60_000, within: 1_000 }, random: () => 0, hidden: () => hidden,
    authenticate: async () => ({ name: "test" }) });
  l.start();
  await wait(5);
  hidden = true;
  sockets[0].onclose({ code: 1006, reason: "" });
  await wait(20);
  assert.equal(sockets.length, 1, "no redial while hidden");
  hidden = false;
  l.retryNow();
  await wait(5);
  assert.equal(sockets.length, 2);
  assert.equal(l.state.kind, "open");
  l.stop();
});

/** A link whose replies are held until the test lets each go, in any order. */
function heldLink(answer) {
  const out = [];
  return {
    out,
    onNotification: () => {},
    onState: () => {},
    call: (method, params, host) => new Promise((resolve) => out.push({ method, params, host, reply: () => resolve(answer(method, params, host)) })),
    /** The first held call of `method`, answered and let go. */
    async answer(method) {
      const at = out.findIndex((c) => c.method === method);
      assert.ok(at >= 0, `a ${method} is out`);
      const [call] = out.splice(at, 1);
      call.reply();
      await wait(0);
      return call;
    },
  };
}

test("a search asks each host for a capped page of matches and holds one search's at a time (#193)", async () => {
  const lists = [];
  const archived = (id, at) => agent(id, "p", at, { state: "archived" });
  const link = fakeLink((method, params, host) => {
    if (method !== "agents/list") return undefined;
    lists.push({ host, ...params });
    if (host === "box") return [archived("box-old", 1)];
    // A full page from the Mac, then a short one after the cursor.
    if (!params.after) return [agent("live", "p", 900), ...Array.from({ length: searchShown - 1 }, (_, i) => archived(`m${i}`, 800 - i))];
    return [archived("m-more", 1)];
  });
  const store = new Store(link);
  store.hosts.value = [{ id: "mac", state: "online" }, { id: "box", state: "online" }, { id: "off", state: "offline" }];
  store.replaceAgents([agent("live", "p", 900)], "mac");

  await store.searchSessions("seeded ar");
  assert.deepEqual(lists.map((l) => [l.host, l.query, l.limit, l.lean, l.archivedCommands]),
    [["mac", "seeded ar", searchShown, true, false], ["box", "seeded ar", searchShown, true, false]], "an offline host is not asked");
  assert.equal(store.agents.value.mac.length, searchShown);
  assert.deepEqual(Object.keys(store.searchNext.value), ["mac"], "only a full page has more");

  await store.searchMore();
  assert.deepEqual(lists[2].after, { lastActivityAt: 800 - (searchShown - 2), id: `m${searchShown - 2}` }, "the next page starts after the last");
  assert.ok(store.agents.value.mac.some((a) => a.id === "m-more"));
  assert.deepEqual(store.searchNext.value, {});

  // The search ends: what it brought in is let go; the live agent stays.
  await store.searchSessions("");
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["live"]);
  assert.deepEqual(store.agents.value.box, []);
});

test("a search's reply for words no longer asked is dropped (#193)", async () => {
  const link = heldLink((method, params) => [agent(`for-${params.query}`, "p", 1, { state: "archived" })]);
  const store = new Store(link);
  store.hosts.value = [{ id: "mac", state: "online" }];
  const first = store.searchSessions("ab");
  const second = store.searchSessions("abc");
  await link.answer("agents/list");
  await link.answer("agents/list");
  await Promise.all([first, second]);
  assert.deepEqual((store.agents.value.mac ?? []).map((a) => a.id), ["for-abc"]);
});

test("two quick drops are sent one at a time, and the host and page end with the last (#193)", async () => {
  const tiles = ["a", "b", "c"];
  let hostOrder = { sections: [{ tiles }] };
  const link = heldLink((method, params) => {
    if (method === "dashboard/arrange") { hostOrder = params.order; return null; }
    return { folder: "file:///w/p", tiles: [], now: 0, order: hostOrder };
  });
  const store = new Store(link);
  const key = "mac|file:///w/p";
  const shown = () => store.dashboards.value[key]?.order.sections[0].tiles.join("");

  // The page opens and a dashboard/changed refresh is out, from before the drops.
  const opening = store.openDashboard("mac", "file:///w/p");
  await link.answer("dashboard/get");
  await opening;
  const early = store.loadDashboard("mac", "file:///w/p");

  const first = store.arrangeDashboard("mac", "file:///w/p", { sections: [{ tiles: ["b", "a", "c"] }] });
  const second = store.arrangeDashboard("mac", "file:///w/p", { sections: [{ tiles: ["c", "b", "a"] }] });
  assert.equal(shown(), "cba");
  assert.equal(link.out.filter((c) => c.method === "dashboard/arrange").length, 1, "one send at a time");

  // The early refresh lands with the host's old order: the drop stays on the page.
  await link.answer("dashboard/get");
  await early;
  assert.equal(shown(), "cba");

  await link.answer("dashboard/arrange");
  const next = await link.answer("dashboard/arrange");
  assert.deepEqual(next.params.order.sections[0].tiles, ["c", "b", "a"], "the newest drop goes next");
  await second;
  await link.answer("dashboard/get");
  await first;
  assert.deepEqual(hostOrder.sections[0].tiles, ["c", "b", "a"]);
  assert.equal(shown(), "cba");
  assert.equal(link.out.length, 0);
});

function ran(n, id, extra = {}) {
  return entry(n, { [n === id ? "toolCall" : "toolCallUpdate"]: { _0: { toolCallID: `c${id}`, title: "Run", status: "in_progress", ...extra } } });
}

test("a followed turn of few rows and many entries holds a bounded number of entries (#214)", () => {
  const work = new Work();
  work.watch("mac", "s");
  work.replaceTranscript({ entries: [], firstIndex: 0 });
  let n = 0;
  work.apply("agent/entry", { agentID: "s", entry: asked(n++) }, "mac");
  // Ten calls, each updated five hundred times: two rows, five thousand entries.
  for (let c = 0; c < 10; c++) {
    const id = n;
    for (let u = 0; u <= 500; u++, n++) work.apply("agent/entry", { agentID: "s", entry: ran(n, id, { rawOutput: { out: `${n}` } }) }, "mac");
  }
  assert.equal(work.items.value.length, 2, "the ask and one run");
  assert.ok(work.entries.value.length <= 800, `held ${work.entries.value.length}`);
  assert.equal(work.firstEntryIndex.value + work.entries.value.length, n, "where it starts is counted");
  assert.equal(work.hasMoreBefore.value, true);
  const run = work.items.value[1];
  assert.equal(run.calls.length, 10, "the rows stay as folded");
  assert.equal(run.calls[9].rawOutput.out, `${n - 1}`, "and keep folding");
  // Reaching the top pages the let-go entries back in, and the run is folded from all of them.
  const before = work.firstEntryIndex.value;
  const all = [asked(0)];
  for (let c = 0, k = 1; c < 10; c++) { const id = k; for (let u = 0; u <= 500; u++, k++) all.push(ran(k, id, { rawOutput: { out: `${k}` } })); }
  work.prepend({ entries: all.slice(0, before), firstIndex: 0 });
  assert.equal(work.entries.value.length, n, "nothing held twice");
  assert.equal(work.items.value[1].calls.length, 10);
});

test("entries heard are kept for a page only while one is on its way (#214)", () => {
  const work = new Work();
  work.watch("mac", "s");
  work.apply("agent/entry", { agentID: "s", entry: said(1) }, "mac");
  work.replaceTranscript({ entries: [asked(0)], firstIndex: 0 });
  assert.deepEqual(work.entries.value.map((e) => e.id), ["e0", "e1"], "heard before the page, laid over it");
  for (let i = 2; i < 50; i++) work.apply("agent/entry", { agentID: "s", entry: said(i) }, "mac");
  // A page after that lays nothing heard before it over itself: none was collected.
  work.replaceTranscript({ entries: [asked(100)], firstIndex: 100 });
  assert.deepEqual(work.entries.value.map((e) => e.id), ["e100"]);
});

test("a heartbeat answered with an error keeps the link (#214)", async () => {
  const sockets = [];
  const l = new w.Link({ url: "ws://localhost:1/v1/connect", origin: "http://localhost:1",
    keys: Object.assign(new w.MemoryKeyStore(), { record: { privateKey: {}, publicKey: {}, client: "C", control: "K", paired: "" } }),
    open: () => {
      const socket = { closed: null, onopen: null, onmessage: null, onclose: null, onerror: null,
        send(line) {
          const { m } = JSON.parse(line);
          setTimeout(() => this.onmessage?.({ data: JSON.stringify({ m: { jsonrpc: "2.0", id: m.id, error: { code: -32000, message: "busy" } } }) }), 1);
        },
        close(code) { this.closed = code; } };
      sockets.push(socket);
      setTimeout(() => socket.onopen?.({}), 0);
      return socket;
    },
    backoff: [0.01], heartbeat: { every: 10, within: 20 }, random: () => 0,
    authenticate: async () => ({ name: "test" }) });
  l.start();
  await wait(120);
  assert.equal(sockets.length, 1, "never redialled");
  assert.equal(sockets[0].closed, null);
  assert.equal(l.state.kind, "open");
  l.stop();
});

test("a slow call waits longer than an ordinary one, unless a test says otherwise (#291)", () => {
  assert.equal(w.callTimeoutFor("hosts/list"), 30_000);
  assert.equal(w.callTimeoutFor("agents/prompt"), 30_000);
  assert.ok(w.callTimeoutFor("projects/clone") > w.callTimeoutFor("agents/start"));
  assert.equal(w.callTimeoutFor("agents/start"), 2 * 60_000);
  assert.equal(w.callTimeoutFor("agents/options"), w.callTimeoutFor("agents/start"));
  assert.equal(w.callTimeoutFor("dashboard/update"), w.callTimeoutFor("agents/start"));
  assert.equal(w.callTimeoutFor("projects/clone", 20), 20);
  assert.equal(w.callTimeoutFor("hosts/list", 20), 20);
});

test("one start keeps its request until it succeeds (#291)", () => {
  const store = new Store(fakeLink(() => undefined));
  const first = store.startRequestID("mac", "file:///w/p");
  assert.equal(store.startRequestID("mac", "file:///w/p/"), first, "the same project, slash or none");
  assert.notEqual(store.startRequestID("mac", "file:///w/q"), first);
  store.finishStartRequest("mac", "file:///w/p");
  assert.notEqual(store.startRequestID("mac", "file:///w/p"), first);
});

test("an opened turn asks for its last page, and a miss reports the turn's start (#291)", async () => {
  const link = heldLink((method, params) => ({
    entries: [said(params.before - 1)], firstIndex: Math.max(params.from, params.before - params.limit), total: params.before,
  }));
  const store = new Store(link);
  const pending = store.turnEntries("mac", "s", { start: 0, end: 500 });
  const call = await link.answer("agents/transcript");
  assert.equal(call.params.limit, turnPage);
  assert.equal(call.params.before, 500);
  assert.equal(call.params.from, 0);
  const page = await pending;
  assert.equal(page.firstIndex, 500 - turnPage);
  const earlier = store.turnEntries("mac", "s", { start: 0, end: page.firstIndex });
  const again = await link.answer("agents/transcript");
  assert.equal(again.params.before, page.firstIndex);
  assert.equal(again.params.limit, turnPage);
  await earlier;
  const missed = await new Store(fakeLink(() => undefined)).turnEntries("mac", "s", { start: 4, end: 9 });
  assert.deepEqual(missed, { entries: [], firstIndex: 4 });
  const empty = await store.turnEntries("mac", "s", { start: 3, end: 3 });
  assert.deepEqual(empty, { entries: [], firstIndex: 3 });
  assert.equal(link.out.length, 0, "an empty span asks for nothing");
});

test("eight opened turns are kept, and the oldest goes (#291)", () => {
  let held = {};
  let order = [];
  for (let i = 0; i < openTurnsHeld + 1; i++) ({ held, order } = rememberOpen(held, order, `t${i}`, i));
  assert.equal(order.length, openTurnsHeld);
  assert.equal(held.t0, undefined);
  assert.equal(held[`t${openTurnsHeld}`], openTurnsHeld);
  ({ held, order } = rememberOpen(held, order, "t1", 1));
  assert.equal(order.at(-1), "t1", "opening it again makes it the newest");
  assert.equal(order.length, openTurnsHeld);
});

test("history stops at its cap, and a full chat does not ask for another page (#291)", async () => {
  const work = new Work();
  work.watch("mac", "s");
  const summary = (i) => ({ id: `t${i}`, start: i, end: i + 1 });
  work.replaceTurns({ turns: Array.from({ length: historyTurnsCap }, (_, i) => summary(i)), firstTurn: 0, openStart: historyTurnsCap });
  work.prependTurns({ turns: [summary(historyTurnsCap)], firstTurn: 0 });
  assert.equal(work.turns.value.length, historyTurnsCap);
  assert.equal(work.turns.value.some((t) => t.id === `t${historyTurnsCap}`), false);

  const link = fakeLink(() => ({ entries: [], firstIndex: 0 }));
  const store = new Store(link);
  store.watch("mac", "s");
  store.replaceTranscript({ entries: Array.from({ length: historyEntriesCap }, (_, n) => said(n)), firstIndex: 10 });
  await store.loadEarlier();
  assert.equal(link.asked.some((line) => line.endsWith("agents/transcript")), false);
});

test("a dashboard on screen settles its changes, and a closed one is dropped (#291)", async () => {
  let gets = 0;
  const link = fakeLink((method) => {
    if (method !== "dashboard/get") return undefined;
    gets += 1;
    return { folder: "file:///w/p", tiles: [], now: gets, order: { sections: [] } };
  });
  const store = new Store(link);
  await store.openDashboard("mac", "file:///w/p");
  assert.equal(gets, 1);
  const changed = (bad) => store.apply("dashboard/changed", { folder: "file:///w/p", summary: { bad } }, "mac");
  changed(0);
  changed(1);
  await wait(100);
  assert.equal(gets, 1, "a burst is one read");
  await wait(quietSettle);
  assert.equal(gets, 2);
  store.closeDashboard("mac", "file:///w/p");
  assert.equal(store.dashboards.value["mac|file:///w/p"], undefined);
  changed(2);
  await wait(quietSettle + 40);
  assert.equal(gets, 2, "a closed dashboard is not read");
});

test("pages changed in a burst bump the revision once (#291)", async () => {
  const work = new Work();
  work.apply("pages/changed", { folder: "file:///w/p" }, "mac");
  work.apply("pages/changed", { folder: "file:///w/p" }, "mac");
  assert.equal(work.pageRevisions.value["mac|file:///w/p"], undefined);
  await wait(quietSettle + 40);
  assert.equal(work.pageRevisions.value["mac|file:///w/p"], 1);
});

test("a workflow change redraws that project's list and no other (#291)", async () => {
  const link = fakeLink((method) => (method === "workflows/list" ? [] : undefined));
  const store = new Store(link);
  store.holdWorkflows("mac", "file:///w/p1");
  store.holdWorkflows("mac", "file:///w/p2");
  await wait(20);
  const first = runs(() => store.projectWorkflows("mac", "file:///w/p1"));
  const second = runs(() => store.projectWorkflows("mac", "file:///w/p2"));
  store.apply("workflow/changed", { workflow: { folder: "file:///w/p1", workflowID: "w" } }, "mac");
  assert.deepEqual([first.count, second.count], [1, 0]);
  first.stop();
  second.stop();
});

test("a reconnect lists the workflow folds still open, and no other (#291)", async () => {
  const listed = [];
  const link = fakeLink((method, params) => {
    if (method === "hosts/list") return [{ id: "mac", state: "online" }];
    if (method === "agents/list") return [];
    if (method === "workflows/list") { listed.push(params.folder); return []; }
    if (method.endsWith("/pending")) return [];
    return undefined;
  });
  const store = new Store(link);
  store.holdWorkflows("mac", "file:///w/kept");
  store.holdWorkflows("mac", "file:///w/gone");
  store.releaseWorkflows("mac", "file:///w/gone");
  await wait(20);
  listed.length = 0;
  await store.load();
  await wait(30);
  assert.deepEqual(listed, ["file:///w/kept"]);
});

test("a host removed takes its dashboards, pages, runtimes and leases with it (#291)", async () => {
  const hosts = [{ id: "mac", state: "online" }, { id: "box", state: "online" }];
  const link = fakeLink((method) => (method === "hosts/list" ? hosts : undefined));
  const store = new Store(link);
  const dash = { folder: "file:///w/p", tiles: [], now: 0, order: { sections: [] } };
  store.dashboards.value = { "box|file:///w/p": dash, "mac|file:///w/p": dash };
  store.dashboardRevisions.value = { "box|file:///w/p": 2, "mac|file:///w/q": 1 };
  store.pageRevisions.value = { "box|file:///w/p": 4, "mac|file:///w/p": 5 };
  store.runtimes.value = { box: [], mac: [] };
  store.accounts.value = { box: [], mac: [] };
  store.leases.value = { box: {}, mac: {} };
  store.workflows.value = { "box|file:///w/p": [], "mac|file:///w/p": [] };
  hosts.pop();
  link.notify("control/hostChanged", { host: "box", state: "removed" });
  await wait(320);
  assert.equal(store.dashboards.value["box|file:///w/p"], undefined);
  assert.ok(store.dashboards.value["mac|file:///w/p"]);
  assert.equal(store.dashboardRevisions.value["box|file:///w/p"], undefined);
  assert.equal(store.dashboardRevisions.value["mac|file:///w/q"], 1);
  assert.equal(store.pageRevisions.value["box|file:///w/p"], undefined);
  assert.equal(store.pageRevisions.value["mac|file:///w/p"], 5);
  assert.equal(store.runtimes.value.box, undefined);
  assert.ok(store.runtimes.value.mac);
  assert.equal(store.accounts.value.box, undefined);
  assert.equal(store.leases.value.box, undefined);
  assert.equal(store.workflows.value["box|file:///w/p"], undefined);
  assert.ok(store.workflows.value["mac|file:///w/p"]);
});

test("loading a host and reloading it do not list its agents at once (#291)", async () => {
  const hosts = [{ id: "mac", state: "online" }];
  let inflight = 0;
  let max = 0;
  const held = [];
  let notify = () => {};
  const link = {
    onNotification(listener) { notify = listener; },
    onState() {},
    call(method) {
      if (method === "hosts/list") return Promise.resolve(hosts);
      if (method === "agents/list") {
        inflight += 1;
        max = Math.max(max, inflight);
        return new Promise((resolve) => held.push(() => { inflight -= 1; resolve([]); }));
      }
      if (String(method).endsWith("/pending")) return Promise.resolve([]);
      return Promise.resolve(null);
    },
  };
  const store = new Store(link);
  const loading = store.load();
  await wait(20);
  assert.equal(inflight, 1);
  notify("control/hostChanged", { host: "mac", state: "online" });
  await wait(300);
  assert.equal(max, 1, "the reload waits for the load");
  while (held.length) held.shift()();
  await loading;
  await wait(30);
  while (held.length) held.shift()();
  await wait(30);
  assert.equal(max, 1);
});
