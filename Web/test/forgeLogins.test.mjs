// Settings ▸ GitHub, GitLab and Linear on the web (#3160), as the window's Settings ▸ Account has them (#2951).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/forgeLogins.ts");

test("the fields are filled from the caller's own entry, blank when not given", () => {
  const list = { people: [
    { id: "a", name: "Sam", kind: "person", githubLogin: "sam" },
    { id: "b", name: "Me", kind: "person", you: true, githubLogin: "me-gh", linearLogin: "me" },
  ] };
  assert.deepEqual(f.myLogins(list), { github: "me-gh", gitlab: "", linear: "me" });
  assert.deepEqual(f.myLogins({ people: [] }), { github: "", gitlab: "", linear: "" });
});

test("a save sends each trimmed, blank to clear, and only when something changed", () => {
  assert.deepEqual(f.loginsToSave({ github: "  me ", gitlab: "", linear: undefined }), { github: "me", gitlab: "", linear: "" });
  const kept = { github: "me", gitlab: "", linear: "" };
  assert.equal(f.loginsChanged(kept, { github: " me ", gitlab: "", linear: "" }), false);
  assert.equal(f.loginsChanged(kept, { github: "", gitlab: "", linear: "" }), true);
});

test("its words are the window's", () => {
  assert.equal(f.forgeLoginsTitle, "GitHub, GitLab and Linear");
  assert.deepEqual(f.forgeLoginFields.map((x) => x.label), ["GitHub login", "GitLab login", "Linear login"]);
});
