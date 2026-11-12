// The ⌘K command menu's finding and order (#4788), the same cases as the window's CommandFinderTests (#4787),
// so the web page and the Mac find the same items in the same order.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/commandMenu.ts");

const items = [
  { id: "action:archive", kind: "action", title: "Archive Session" },
  { id: "action:new", kind: "action", title: "New Session" },
  { id: "session:1", kind: "session", title: "Fix the sign-in sheet", detail: "Agents" },
  { id: "session:2", kind: "session", title: "Archive old logs", detail: "Tools" },
  { id: "folder:/a", kind: "folder", title: "Agents", detail: "This Mac" },
  { id: "issue:github:alexec/Agents#4777", kind: "issue", title: "As fast as Linear", detail: "alexec/Agents", ref: "#4777" },
  { id: "pr:github:alexec/Agents#4809", kind: "pr", title: "Inline error text", detail: "alexec/Agents", ref: "#4809" },
];
const ids = (list) => list.map((i) => i.id);

test("no words keeps the order given, up to the limit", () => {
  assert.deepEqual(ids(c.commandMatches(items, "  ")), ids(items));
  assert.equal(c.commandMatches(items, "", 2).length, 2);
});

test("every word must be in the item", () => {
  assert.deepEqual(ids(c.commandMatches(items, "sign sheet")), ["session:1"]);
  assert.deepEqual(c.commandMatches(items, "sign nothing"), []);
});

test("a title that starts with the query comes first, then the kinds' order", () => {
  assert.deepEqual(ids(c.commandMatches(items, "archive")), ["action:archive", "session:2"]);
  assert.equal(c.commandMatches(items, "in")[0].id, "pr:github:alexec/Agents#4809");
});

test("a ref finds its item above words", () => {
  assert.equal(c.commandMatches(items, "#4777")[0].id, "issue:github:alexec/Agents#4777");
  assert.equal(c.commandMatches(items, "4777")[0].id, "issue:github:alexec/Agents#4777");
  assert.equal(c.commandMatches(items, "P#4809")[0].id, "pr:github:alexec/Agents#4809");
});

test("the detail and the keywords find too", () => {
  assert.deepEqual(ids(c.commandMatches(items, "tools")), ["session:2"]);
  assert.deepEqual(ids(c.commandMatches([{ id: "s", kind: "session", title: "x", keywords: ["Find Session"] }], "find")), ["s"]);
});

test("a ref typed alone", () => {
  assert.equal(c.typedRef("#12").number, 12);
  assert.equal(c.typedRef("12").pr, undefined);
  assert.equal(c.typedRef("P#12").pr, true);
  assert.equal(c.typedRef("!7").pr, true);
  assert.equal(c.typedRef("#"), undefined);
  assert.equal(c.typedRef("fix 12"), undefined);
  assert.equal(c.typedRef("#0"), undefined);
});

test("a ref no item has opens in each repo read", () => {
  const made = c.refItems("#5", ["github:alexec/Agents"], []);
  assert.deepEqual(ids(made), ["issue:github:alexec/Agents#5", "pr:github:alexec/Agents#5"]);
  assert.equal(made[0].title, "Open issue #5");
  assert.equal(made[0].detail, "alexec/Agents");
  assert.deepEqual(ids(c.refItems("P#5", ["gitlab:o/r"], [])), ["pr:gitlab:o/r!5"]);
  assert.deepEqual(ids(c.refItems("#4777", ["github:alexec/Agents"], items)), ["pr:github:alexec/Agents#4777"]);
  assert.deepEqual(c.refItems("fix", ["github:alexec/Agents"], []), []);
  assert.deepEqual(ids(c.commandFound(items, "#4777", ["github:alexec/Agents"])),
    ["issue:github:alexec/Agents#4777", "pr:github:alexec/Agents#4777"]);
});

test("⌘K or Ctrl+K, with no other modifier, and the keys as the computer says them", () => {
  const key = (k, more = {}) => ({ key: k, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...more });
  assert.equal(c.isCommandMenuKey(key("k", { metaKey: true })), true);
  assert.equal(c.isCommandMenuKey(key("K", { ctrlKey: true })), true);
  assert.equal(c.isCommandMenuKey(key("k")), false);
  assert.equal(c.isCommandMenuKey(key("k", { metaKey: true, shiftKey: true })), false);
  assert.equal(c.commandKey("f", true), "⌘F");
  assert.equal(c.commandKey("f", false), "Ctrl+F");
});
