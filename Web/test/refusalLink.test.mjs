// A hosted refusal's account page, offered as a link beside Try Now (#3153), as
// ControlRefusalLinkTests checks it in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { refusalLink } = await load("src/views/Banner.tsx");

test("a suspension's account page, without the full stop", () => {
  assert.equal(refusalLink("This hosted account is suspended. See https://example.com/account."), "https://example.com/account");
});

test("a plan's upgrade page", () => {
  assert.equal(refusalLink("Your free plan allows 3. Stop one, or upgrade at https://example.com/account."), "https://example.com/account");
});

test("no address, or one not https, is no link", () => {
  assert.equal(refusalLink("This account is over its plan's limit."), undefined);
  assert.equal(refusalLink("See http://example.com/account."), undefined);
});
