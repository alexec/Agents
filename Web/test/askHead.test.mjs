// A question card's head (#5028): a confirm card's one question is its title.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { askHead } = await load("src/model/askHead.ts");

const form = (schema, extra = {}) => ({ id: "r", agentID: "a", askedAt: 0, scope: "session", mode: { form: { _0: schema } }, ...extra });
const choices = { string: { choices: [{ value: "yes", title: "Start it" }, { value: "no", title: "Don’t" }] } };

test("a confirm card's question is its title, not who asks", () => {
  const wants = "Claude (Lead #4207) wants to start a session on devbox";
  const request = form({ title: wants, properties: [{ name: "go", title: "Start a session on devbox, in ~/Agents, to fix #4990?", isRequired: true, kind: choices }] },
    { message: wants });
  assert.deepEqual(askHead(request), { title: "Start a session on devbox, in ~/Agents, to fix #4990?" });
});

test("a form of several questions keeps its title and its message", () => {
  const request = form({ title: "Set up", properties: [
    { name: "a", title: "Which colour?", isRequired: true, kind: choices },
    { name: "b", title: "Why?", isRequired: false, kind: { string: {} } },
  ] }, { message: "Two things first" });
  assert.deepEqual(askHead(request), { title: "Set up", message: "Two things first" });
});

test("a secret's one field is its reason, never the title", () => {
  const request = form({ title: "An API key", properties: [{ name: "s", title: "For the deploy", isRequired: true, kind: choices }] },
    { secret: { name: "KEY" } });
  assert.equal(askHead(request).title, "An API key");
});

test("a page to open keeps its own words", () => {
  assert.deepEqual(askHead({ id: "r", agentID: "a", mode: { url: { _0: "https://example.com" } } }), { title: "The agent wants you to open a page" });
});
