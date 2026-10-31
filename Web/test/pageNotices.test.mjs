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

// Web Push (#1486): what the worker shows, where it can be had, and what Settings says.
const pushItem = await load("src/pushItem.ts");

test("a Web Push shows the need's words, buzzing only for an alert, one a need", () => {
  const shown = pushItem.notificationFor({ needID: { permission: "P" }, alert: true, headline: { h1: "work", h2: "Fix the gallery", h3: "may run" } });
  assert.equal(shown.title, "Fix the gallery");
  assert.equal(shown.options.body, "may run");
  assert.equal(shown.options.silent, false);
  assert.equal(shown.options.tag, 'need:{"permission":"P"}');
  const quiet = pushItem.notificationFor({ needID: { permission: "P" }, alert: false });
  assert.equal(quiet.title, "Agents");
  assert.equal(quiet.options.body, "An agent needs you");
  assert.equal(quiet.options.silent, true);
});

test("Web Push needs a worker and a push manager; on iOS, the Home Screen", () => {
  assert.equal(pageNotices.webPushHere(true, true, false), "off");
  assert.equal(pageNotices.webPushHere(true, false, true), "homeScreen");
  assert.equal(pageNotices.webPushHere(false, false, false), "unsupported");
  assert.match(pageNotices.webPushText("homeScreen"), /Home Screen/);
  assert.match(pageNotices.webPushText("on"), /page closed/);
  assert.match(pageNotices.webPushText("none"), /no Web Push/);
  assert.equal(pageNotices.webPushText("off"), "");
});

test("a key is said in base64url without padding", () => {
  assert.equal(pageNotices.base64url(new Uint8Array([251, 255, 0]).buffer), "-_8A");
  assert.equal(pageNotices.base64url(null), "");
});
