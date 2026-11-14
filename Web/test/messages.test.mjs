// The Messages page (#4344): the machines' conversations in one list, and its place in the bar.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/messages.ts");
const nav = await load("src/model/nav.ts");
const route = await load("src/route.ts");

const item = (source, id, at, unread) => ({
  server: source, folder: "/p",
  conversation: { source, id, title: id, kind: "channel", ...unread === undefined ? {} : { unread }, ...at ? { lastActivity: at } : {} },
});

test("the machines merge newest first, each conversation once, this Mac's copy kept", () => {
  const lists = [
    { host: "mac", name: "This Mac", conversations: [item("slack", "C1", "2026-11-10T08:00:00Z"), item("email", "t1")], errors: [] },
    { host: "box", name: "Box", conversations: [item("slack", "C1", "2026-11-10T08:00:00Z"), item("slack", "C2", "2026-11-10T09:00:00.5Z")], errors: [] },
  ];
  const rows = m.mergeConversations(lists);
  assert.deepEqual(rows.map((r) => r.item.conversation.id), ["C2", "C1", "t1"]);
  assert.equal(rows[1].host, "mac");
  assert.deepEqual(m.mergeConversations(lists, "email").map((r) => r.key), ["email:t1"]);
  assert.deepEqual(m.messagesSources(lists), ["email", "slack"]);
});

test("no connector is no conversation and no error; problems say the machine and the connector", () => {
  assert.equal(m.noConnectorIn([{ host: "mac", name: "This Mac", conversations: [], errors: [] }]), true);
  const failed = { host: "box", name: "Box", conversations: [], errors: [{ server: "slack", folder: "/p", message: "No token." }] };
  assert.equal(m.noConnectorIn([failed]), false);
  assert.deepEqual(m.messagesProblems([failed]), ["Box ▸ slack: No token."]);
  assert.deepEqual(m.messagesProblems([{ host: "mac", name: "This Mac", conversations: [], errors: [], problem: "Offline." }]), ["This Mac: Offline."]);
});

test("a row's words are the window's", () => {
  assert.equal(m.unreadWords(item("slack", "C1", undefined, 3).conversation), "3 unread");
  assert.equal(m.unreadWords(item("slack", "C1", undefined, 0).conversation), undefined);
  assert.equal(m.senderName({ channel: "slack", identity: "U1", name: "Sam" }), "Sam");
  assert.equal(m.senderName({ channel: "email", identity: "sam@example.com" }), "sam@example.com");
});

test("Messages is Work's page after Docs (#5267), #/work/messages/<key> is a conversation's page, and #/messages/<key> still opens it", () => {
  assert.ok(!nav.navSections.includes("messages"));
  assert.equal(nav.navPages.work[1].id, "messages");
  const hash = route.routeHash({ nav: "work", section: "messages", item: "slack:C1" });
  assert.equal(hash, "#/work/messages/slack%3AC1");
  assert.deepEqual(route.parseRoute(hash), { nav: "work", section: "messages", item: "slack:C1" });
  assert.deepEqual(route.parseRoute("#/messages/slack%3AC1"), { nav: "work", section: "messages", item: "slack:C1" });
  assert.deepEqual(route.parseRoute("#/messages"), { nav: "work", section: "messages" });
});

test("the reply field (#4345) sends trimmed text and says who it goes as", () => {
  assert.equal(m.replyText("  On it.\n"), "On it.");
  assert.equal(m.replyText(" \n "), undefined);
  assert.equal(m.sentAs("the Slack bot @agents"), "Sent as the Slack bot @agents, not as an agent.");
});

test("the line at the head of Messages says the unread and what the last message woke (#4934)", () => {
  const ref = Date.UTC(2001, 0, 1);
  const now = ref + 10_000_000_000;
  const event = (position, name, at, consequences = []) => ({ position, name, at, count: 1, scope: { mac: {} }, sentence: "",
    details: {}, chainDepth: 0, consequences });
  const woke = event(1, "message.received", 9_999_760, [{ fired: { workflowID: "triage", folder: "/p" } },
    { woke: { agentID: "a", title: "Fix login bug" } }]);
  const last = m.lastConsequence([woke, event(2, "agent.started", 9_999_990)]);
  assert.deepEqual(last, { at: ref + 9_999_760_000, words: "woke Fix login bug" });
  assert.equal(m.messagesStatusLine(12, last, now), "12 unread · woke Fix login bug 4 min ago");
  assert.equal(m.lastConsequence([event(3, "message.received", 1, [{ fired: { workflowID: "triage", folder: "/p" } }])]).words, "started triage");
  const nothing = event(4, "message.received", 9_999_880, [{ refused: { workflowID: "triage", folder: "/p", reason: { disabled: {} } } }]);
  assert.equal(m.messagesStatusLine(0, m.lastConsequence([woke, nothing]), now), "nothing woke 2 min ago");
  assert.equal(m.messagesStatusLine(undefined, undefined, now), undefined);
  assert.equal(m.messagesStatusLine(3, undefined, now), "3 unread");
  const lists = [
    { host: "mac", name: "This Mac", conversations: [item("slack", "C1", "2026-11-10T08:00:00Z", 2), item("email", "t1")], errors: [] },
    { host: "box", name: "Box", conversations: [item("slack", "C1", "2026-11-10T08:00:00Z", 2), item("slack", "C2", "2026-11-10T09:00:00Z", 5)], errors: [] },
  ];
  assert.equal(m.unreadTotal(lists), 7);
  assert.equal(m.unreadTotal([{ host: "mac", name: "This Mac", conversations: [item("email", "t")], errors: [] }]), undefined);
});

test("next is the row after in the list as it is filtered now, and marking read sets the count to nought (#5137)", () => {
  const lists = [
    { host: "mac", name: "This Mac", conversations: [item("slack", "C1", "2026-11-10T09:00:00Z"), item("email", "t1", "2026-11-10T08:00:00Z", 2),
      item("slack", "C2", "2026-11-10T07:00:00Z")], errors: [] },
    { host: "box", name: "Box", conversations: [item("email", "t1", "2026-11-10T08:00:00Z", 2), item("email", "t2", "2026-11-10T06:00:00Z", 1)], errors: [] },
  ];
  const all = m.mergeConversations(lists);
  assert.equal(m.nextRow(all, "slack:C1")?.key, "email:t1");
  assert.equal(m.nextRow(all, "email:t2"), undefined);
  assert.equal(m.nextRow(m.mergeConversations(lists, "slack"), "slack:C1")?.key, "slack:C2");
  assert.equal(m.nextRow(all, "slack:gone"), undefined);

  assert.equal(m.hasUnread(lists), true);
  const one = m.markedRead(lists, "email:t1");
  assert.deepEqual(one.flatMap((l) => l.conversations.map((c) => c.conversation.unread)), [undefined, 0, undefined, 0, 1]);
  assert.equal(m.unreadTotal(one), 1);
  const none = m.markedRead(lists);
  assert.equal(m.unreadTotal(none), 0);
  assert.equal(m.hasUnread(none), false);
  assert.equal(m.hasUnread([{ ...none[0], cursor: "more" }]), true);
  assert.deepEqual(m.markProblems([
    { name: "This Mac", marked: { marked: [], errors: [{ server: "mail", folder: "/p", message: "No answer." }] } },
    { name: "Box", problem: "Offline." },
  ]), ["This Mac ▸ mail: No answer.", "Box: Offline."]);
});
