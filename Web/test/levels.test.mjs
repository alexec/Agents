// The words every runtime shares (#2658), held to LevelWords by Fixtures/web/levels/words.json.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const l = await load("src/model/levels.ts");
const names = await load("src/model/switchNote.ts");
const marks = ["autoMapped", "nearestSafer", "yours", "notPossible", "dropped"];

for (const { name, input, expected } of cases("levels/words.json")) {
  test(`levels: ${name}`, () => {
    const field = input.field;
    const levels = l.levelsOf(field);
    const each = (f) => Object.fromEntries(levels.map((v) => [v, f(v)]));
    assert.deepEqual({
      field: l.fieldWords[field],
      levels,
      words: each((v) => l.levelWords(field, v)),
      files: each((v) => l.fileWord(field, v)),
      meanings: each((v) => l.levelMeaning(field, v)),
      marks: Object.fromEntries(marks.map((m) => [m, l.markWords[m]])),
      custom: l.customWords,
      followsSettings: l.followsSettings,
      own: l.ownWords("Claude"),
      on: l.onRuntime("Balanced", "Sonnet 5", "Claude"),
      picks: l.picksWords("Claude"),
      picksNone: l.picksWords(undefined),
      header: l.autoHeader("Claude"),
      noRuntime: l.noRuntimeWords([{ runtimeID: "claude", reason: "out" }, { runtimeID: "codex", reason: "not signed in" }], names.runtimeName),
      continueOn: l.continueOn("Codex"),
    }, expected);
  });
}

for (const { name, input, expected } of cases("runtimes/auto-state.json")) {
  test(`levels: the Auto page's state, ${name} (#2890)`, () => assert.equal(l.unavailableState(input) ?? "Available", expected));
}

// Codex has no bypass mode: Bypass Permissions is Approve for me's options, nearest safer (#2893).
const codex = { cells: [
  { runtimeID: "codex", field: "permission", level: "approveForMe", words: "Default", mark: "autoMapped", native: { options: { mode: "auto" } } },
  { runtimeID: "codex", field: "permission", level: "bypassPermissions", words: "Default", mark: "nearestSafer",
    note: "nearest safer: no mode past Approve for me", native: { options: { mode: "auto" } } },
] };
const value = (id) => (id === "mode" ? "auto" : undefined);

test("levels: the chosen value stays ticked when another sets the same options (#2893)", () => {
  assert.equal(l.matchLevel(codex, "codex", "permission", value), "approveForMe");
  assert.equal(l.matchLevel(codex, "codex", "permission", value, "bypassPermissions"), "bypassPermissions");
  assert.equal(l.matchLevel(codex, "codex", "permission", value, "ask"), "approveForMe");
});

test("levels: a nearest safer value's line says why (#2893)", () => {
  assert.equal(l.cellLine(codex.cells[1], "Codex"), "Default on Codex · nearest safer: no mode past Approve for me");
  assert.equal(l.cellLine(codex.cells[0], "Codex"), "Default on Codex");
  assert.equal(l.cellLine({ ...codex.cells[0], mark: "notPossible", note: "no such mode" }, "Codex"), "Not possible: no such mode");
});
