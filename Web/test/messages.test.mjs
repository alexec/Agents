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

test("Messages is in the bar after Docs, and #/messages/<key> is a conversation's page", () => {
  assert.equal(nav.navSections.indexOf("messages"), nav.navSections.indexOf("docs") + 1);
  const hash = route.routeHash({ nav: "messages", section: "messages", item: "slack:C1" });
  assert.equal(hash, "#/messages/slack%3AC1");
  assert.deepEqual(route.parseRoute(hash), { nav: "messages", section: "messages", item: "slack:C1" });
  assert.deepEqual(route.parseRoute("#/messages"), { nav: "messages" });
});
