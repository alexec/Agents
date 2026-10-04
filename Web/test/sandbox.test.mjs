// A new session's sandbox choice (#257), held to SandboxCatalog and SandboxWords.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const s = await load("src/model/sandbox.ts");
const names = await load("src/model/switchNote.ts");
const all = ["runtime", "on", "off"];
const each = (f) => Object.fromEntries(all.map((c) => [c, f(c)]));

for (const { name, input, expected } of cases("sandbox/choices.json")) {
  test(`sandbox: ${name}`, () => {
    const id = input.runtimeID;
    const mode = input.codexMode ?? undefined;
    assert.deepEqual({
      choices: s.sandboxChoices(id),
      why: s.sandboxWhy(id) ?? null,
      states: each((c) => s.sandboxStateWords(s.sandboxState(id, c, mode))),
      words: each((c) => s.sandboxChoiceWords(c, id)),
      defaults: each((c) => s.sandboxOverrideWords(undefined, c, id)),
      explanations: each((c) => s.sandboxExplanation(c, id, names.runtimeName(id))),
    }, expected);
  });
}
