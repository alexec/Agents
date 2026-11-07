// Personas from a marketplace (#3665, #3678): the add and update sheets' words, as the Mac's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/personaCatalog.ts");
const { CallFailed } = await load("src/wire/link.ts");

const preview = (destinationState) => ({
  previewID: "p", path: "personas/reviewer.md", commit: "abcdef0123", blobSHA: "b", markdown: "---\n---\n",
  result: { id: "r", name: "reviewer", owner: "acme", repo: "kit", skillID: "reviewer", installs: 0, known: false },
  persona: { id: "reviewer", name: "Reviewer", origin: "personal", settings: { options: {}, labels: [] } },
  destinationState,
});

test("an update that changes the permission mode or the runtime says the old and the new value", () => {
  assert.equal(c.settingWarning({ key: "permission-mode", old: "plan", new: "bypassPermissions" }),
    "This update changes the permission mode from plan to bypassPermissions. New sessions with this persona start with it.");
  assert.equal(c.settingWarning({ key: "runtime", new: "codex" }),
    "This update changes the runtime from not set to codex. New sessions with this persona run on it.");
});

test("the daemon's refusal is its own reason; anything else is the failure in words", () => {
  assert.deepEqual(c.catalogError(new CallFailed(-32080, "no", { rateLimited: {} })), { rateLimited: {} });
  assert.ok("failed" in c.catalogError(new Error("boom")));
  assert.equal(c.catalogSentence({ unmanaged: { path: "/Users/a/.agents/personas/x.md" } }),
    "You already have a persona at ~/.agents/personas/x.md. You made it, so the app won't replace it.");
});

test("only GitHub marketplaces hold personas, and the chosen one is the first on when it is off", () => {
  const ms = [
    { id: "sh", format: "skills.sh", enabled: true },
    { id: "a", format: "github-skills", enabled: false },
    { id: "b", format: "github-skills", enabled: true },
  ];
  const gh = c.personaMarketplaces(ms);
  assert.deepEqual(gh.map((m) => m.id), ["a", "b"]);
  assert.equal(c.currentMarketplace(gh, "a")?.id, "b");
  assert.equal(c.currentMarketplace(gh, "b")?.id, "b");
  assert.equal(c.currentMarketplace([], "b"), undefined);
});

test("what is there already decides the button", () => {
  assert.equal(c.addAction(preview({ free: {} })), "add");
  assert.equal(c.destinationNote(preview({ free: {} })), null);
  assert.equal(c.addAction(preview({ sameSkill: { update: false } })), "added");
  assert.equal(c.addAction(preview({ sameSkill: { update: true } })), "replace");
  assert.equal(c.addAction(preview({ managedOther: { source: "x/y" } })), "replace");
  assert.equal(c.addAction(preview({ unmanaged: { path: "/home/a/.agents/personas/reviewer.md" } })), "unmanaged");
  assert.equal(c.destinationNote(preview({ unmanaged: { path: "/home/a/.agents/personas/reviewer.md" } })).text,
    "You already have a persona called reviewer in ~/.agents/personas. You made it, so the app won't replace it.");
});

test("the update mark, where it goes, and where it is from", () => {
  assert.equal(c.hasUpdate({ available: { commit: "x" } }), true);
  assert.equal(c.hasUpdate({ current: {} }), false);
  assert.equal(c.hasUpdate(undefined), false);
  assert.equal(c.goesTo({ kind: "personal" }, "reviewer"), "~/.agents/personas/reviewer.md");
  assert.equal(c.goesTo({ kind: "folder", folder: "/Users/a/code/app" }, "r"), "~/code/app/.agents/personas/r.md");
  assert.equal(c.sourceLine({ source: "acme/kit", commit: "abcdef0123" }), "acme/kit · abcdef0");
  assert.equal(c.sourceLine({ source: "acme/kit" }), "acme/kit");
});
