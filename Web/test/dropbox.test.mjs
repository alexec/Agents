// A file into a project's drop box (#231), by the phone's size rule.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/dropbox.ts");

test("a file within the link's record goes; a bigger one or a dot name is refused", () => {
  assert.equal(d.dropboxRefusal("notes.md", 900_000), null);
  assert.equal(d.dropboxRefusal("film.mov", 2_000_000),
    "From a browser, a drop box file can be 900 KB, and film.mov is 2.0 MB. Copy it into .agents/dropbox/ on its host instead.");
  assert.ok(d.dropboxRefusal(".env", 3));
});

test("the folder typed is inside the drop box, empty for its top", () => {
  assert.equal(d.dropboxSubfolder(""), null);
  assert.equal(d.dropboxSubfolder(" / "), null);
  assert.equal(d.dropboxSubfolder("/review/"), "review");
  assert.equal(d.dropboxSubfolder("review/2026 "), "review/2026");
});

test("the request carries the bytes as base64, and no subfolder at the top", () => {
  const bytes = new TextEncoder().encode("hi");
  assert.deepEqual(d.dropboxRequest("file:///p/", "", "a.txt", bytes),
    { folder: "file:///p/", name: "a.txt", data: "aGk=" });
  assert.deepEqual(d.dropboxRequest("file:///p/", "review", "a.txt", bytes),
    { folder: "file:///p/", subfolder: "review", name: "a.txt", data: "aGk=" });
});
