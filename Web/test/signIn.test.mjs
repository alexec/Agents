import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/signIn.ts");
const request = (over = {}) => ({ request: "r1", name: "Sam's iPhone", kind: "iPhone", provider: "github", login: "sam", code: "K7M2QX",
  expires: 4102444800 - 978307200, ...over });

test("one card per GitHub sign-in, gone when decided or past its end", () => {
  let list = s.withSignIn([], request());
  list = s.withSignIn(list, request({ code: "AAAAAA" }));
  assert.equal(list.length, 1);
  assert.equal(list[0].code, "AAAAAA");
  list = s.withSignIn(list, request({ request: "r2", expires: 0 }));
  assert.equal(s.liveSignIns(list).length, 1);
  assert.equal(s.withoutSignIn(list, "r1").length, 1);
});

test("the words are the window's", () => {
  assert.equal(s.wants(request()), "wants to sign in as you with GitHub (sam).");
  assert.equal(s.row({ provider: "google", account: "1", email: "sam@example.com" }), "Google · sam@example.com");
  assert.equal(s.row({ provider: "github", account: "42", login: "sam" }), "GitHub · sam");
  assert.equal(s.row({ provider: "local", account: "k" }), "This control plane");
  assert.equal(s.isOutside("local"), false);
  assert.deepEqual(s.list(" example.com, ,example.org "), ["example.com", "example.org"]);
});
