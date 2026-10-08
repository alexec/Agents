// What a browser may attach, by the phone's rules (PhoneAttachment).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/attachments.ts");
const utf8 = (s) => new TextEncoder().encode(s);

test("text goes by value, named, with its size", () => {
  const made = a.textAttachment(utf8("héllo"), "notes.md", "text/markdown");
  assert.deepEqual(made.ok.block, { type: "resource", resource: { uri: "browser:notes.md", text: "héllo", mimeType: "text/markdown" } });
  assert.equal(made.ok.displayName, "notes.md");
  assert.equal(made.ok.byteCount, 6);
  assert.match(made.ok.id, /^[0-9A-F-]{36}$/);
});

test("anything that isn't text or a picture is refused in a sentence", () => {
  assert.equal(a.textAttachment(new Uint8Array([0xff, 0xfe, 0x00]), "a.bin", "").refused,
    "a.bin is not a picture or text, so it would have to be on the Mac to attach.");
  assert.ok(a.textAttachment(utf8("a\u0000b"), "z.txt", "text/plain").refused);
});

test("a runtime that won't take it says so before it is sent", () => {
  const picture = a.pictureAttachment(new Uint8Array([1, 2, 3]), "shot.png");
  const text = a.textAttachment(utf8("x"), "x.txt", "text/plain").ok;
  assert.equal(a.refusal(picture, { image: false }), "This runtime does not take pictures");
  assert.equal(a.refusal(picture, { image: true }), null);
  assert.equal(a.refusal(text, {}), "This runtime does not take file contents, so this can only be attached on the Mac");
  assert.equal(a.refusal(text, undefined), null);
});

test("900 KB in all", () => {
  const big = a.textAttachment(utf8("x".repeat(600_000)), "a.txt", "text/plain").ok;
  assert.equal(a.totalRefusal([big]), null);
  assert.equal(a.totalRefusal([big, big]),
    "From a browser, attachments can be 900 KB in all, and these are 1.2 MB. Remove one to send.");
});

// A clipboard as a browser hands it to a paste: items, files and types.
const clipboard = ({ items = [], files = [], types = [] }) => ({ items, files, types });
const item = (kind, file = null) => ({ kind, getAsFile: () => file });

test("a copied screenshot is a clipboard item, and attaches (#396)", () => {
  const shot = new File([new Uint8Array([1])], "image.png", { type: "image/png" });
  assert.deepEqual(a.pastedFiles(clipboard({ items: [item("string"), item("file", shot)] })), [shot]);
});

test("pasted files attach when there are no file items", () => {
  const file = new File(["x"], "notes.md", { type: "text/markdown" });
  assert.deepEqual(a.pastedFiles(clipboard({ files: [file] })), [file]);
  assert.deepEqual(a.pastedFiles(clipboard({ items: [item("string")] })), []);
  assert.deepEqual(a.pastedFiles(null), []);
});

test("words pasted with a picture still go into the field", () => {
  assert.equal(a.pastedWords(clipboard({ types: ["Files", "text/plain"] })), true);
  assert.equal(a.pastedWords(clipboard({ types: ["Files", "text/html"] })), false);
  assert.equal(a.pastedWords(undefined), false);
});
