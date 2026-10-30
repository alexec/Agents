// The page's own notification for a notice (#2860): only a notice sent to the "mac" surface, with
// a sound, while the page is allowed and in front; it names the notice's line.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const pageNotices = await load("src/pageNotices.ts");

const need = { id: { notice: "line" }, kind: "notice", raisedAt: 0, folder: "file:///work/", headline: { h1: "work", h2: "Fix", h3: "Done" } };
const change = { needID: { notice: "line" }, need, to: { mac: {} }, alert: true };

test("a notice sent to the computer posts here while the page is in front", () => {
  assert.equal(pageNotices.noticeToPost(change, "granted", true), "line");
});

test("nothing posts when it is not allowed, not in front, elsewhere, quiet or no notice", () => {
  assert.equal(pageNotices.noticeToPost(change, "default", true), undefined);
  assert.equal(pageNotices.noticeToPost(change, "granted", false), undefined);
  assert.equal(pageNotices.noticeToPost({ ...change, to: { device: "phone" } }, "granted", true), undefined);
  assert.equal(pageNotices.noticeToPost({ ...change, alert: false }, "granted", true), undefined);
  const permission = { needID: { permission: "p" }, need: { ...need, id: { permission: "p" }, kind: "permission" }, to: { mac: {} }, alert: true };
  assert.equal(pageNotices.noticeToPost(permission, "granted", true), undefined);
});

test("the page says whether it may show them", () => {
  assert.match(pageNotices.pagePermissionText("default"), /^Allow notifications/);
  assert.match(pageNotices.pagePermissionText("denied"), /blocks/);
});
