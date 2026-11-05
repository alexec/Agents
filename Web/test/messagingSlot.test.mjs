// The Messaging slot (#1787): None until a chat or email connector is there, then each
// connector's one read and the events it declares.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("the Messaging slot is None until a connector is there", () => {
  const none = { slot: "messaging", choice: "None", state: "skipped" };
  assert.equal(c.heading("messaging"), "Messaging");
  assert.equal(c.title(none), "None");
  assert.match(c.line(none, "walk", undefined, false), /to reach you there too\.$/);
  assert.match(c.line({ ...none, choice: "Slack", servers: ["slack"] }, "walk", undefined, false), /their events with them\.$/);
  assert.equal(c.title({ slot: "messaging", choice: "Slack and Email", state: "read" }), "Slack and Email");
  assert.equal(c.proofLead("messaging"), "Read");
  assert.equal(c.isProjects("messaging"), false);
});

test("each messaging connector says what it read, and its events", () => {
  assert.equal(c.messaging.serverLine({ name: "slack", word: "Slack", state: "read", proof: { title: "3 channels" },
    events: ["slack.message"] }), "Slack (slack): read 3 channels; events slack.message");
  assert.equal(c.messaging.serverLine({ name: "Email", word: "Email", state: "notRead" }), "Email: reading…");
  assert.equal(c.messaging.serverLine({ name: "gmail", word: "Email", state: "failed", message: "It wants a sign-in first." }),
    "Email (gmail): It wants a sign-in first.");
});
