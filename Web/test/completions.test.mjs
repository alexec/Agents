// The `/` command list and `@` file mentions (#255), held to what SlashCommand and FileMention do.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const c = await load("src/model/completions.ts");

for (const { name, input, expected } of cases("completions/typed.json")) {
  test(`completions: ${name}`, () => {
    const command = c.commandQuery(input.text);
    const mention = c.mentionQuery(input.text);
    const matching = command ? c.matchingCommands(command.term, input.commands) : [];
    assert.deepEqual({
      command: command?.term ?? null,
      matching: matching.map((m) => m.name),
      completedCommand: command && matching[0] ? c.completeCommand(input.text, command, matching[0]) : null,
      mention: mention?.term ?? null,
      completedMention: mention ? c.completeMention(input.text, mention, c.fileName("/fixture/project/Web/src/Prompt.tsx")) : null,
    }, expected);
  });
}

test("completions: a mentioned file goes as the host's file URL", () => {
  assert.equal(c.fileURL("/Users/a/My Project/a#b.md"), "file:///Users/a/My%20Project/a%23b.md");
});
