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
