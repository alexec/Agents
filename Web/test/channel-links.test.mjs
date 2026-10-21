// The link card's and Settings ▸ Channels' words (#1762), as the window and the Remote have them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/channelLinks.ts");

const request = (over = {}) => ({ request: "r1", channel: "slack", identity: "T1/U42", name: "@sam", email: "sam@example.com",
  for: "sam", expires: 4102444800 - 978307200, ...over });

test("the card asks to link the identity to you, or tells an admin it names nobody", () => {
  assert.equal(c.ask(request()), "Link Slack user @sam to you?");
  assert.equal(c.detail(request()), "T1/U42 · sam@example.com");
  assert.equal(c.ask(request({ channel: "email", identity: "sam@example.com", name: undefined })), "Link the email address sam@example.com to you?");
  assert.equal(c.detail(request({ channel: "email" })), null);
  assert.equal(c.ask(request({ channel: "discord", identity: "1234", name: undefined, for: undefined })), "Discord user 1234 is not linked to anyone.");
  assert.match(c.explanation(request({ for: undefined })), /^Send asks/);
  assert.match(c.explanation(request()), /^Approve lets/);
});

test("a link says whose it is", () => {
  const link = { channel: "slack", identity: "T1/U42", name: "@sam", user: "sam", userName: "Sam", approvedBy: "sam", approvedAt: 0 };
  assert.equal(c.linkTitle(link), "Slack user @sam");
  assert.equal(c.linkDetail(link, "sam"), "T1/U42 · linked to you");
  assert.equal(c.linkDetail(link, "alex"), "T1/U42 · linked to Sam");
  assert.equal(c.removeTitle(link), "Unlink Slack user @sam?");
});

test("one card per request, gone when decided or past its end", () => {
  let list = c.withRequest([], request());
  list = c.withRequest(list, request({ name: "@samuel" }));
  assert.equal(list.length, 1);
  assert.equal(list[0].name, "@samuel");
  list = c.withRequest(list, request({ request: "old", expires: 0 }));
  assert.equal(c.liveRequests(list).length, 1);
  assert.equal(c.withoutRequest(list, "r1").length, 1);
});
