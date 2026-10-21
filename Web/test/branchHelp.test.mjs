// Branch from Here says the files stay as they are now (#1871): the page's two items, the
// Mac and Remote's help and the host's note use the same words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const words = "The files stay as they are now.";

test("every Branch from Here says the files stay as they are now (#1871)", () => {
  for (const path of ["Web/src/views/chat/PromptList.tsx", "Web/src/views/chat/Rows.tsx"]) {
    const items = read(path).match(/title="[^"]*"\s+onClick=\{[^}]*\}>Branch from Here</g) ?? [];
    assert.ok(items.length > 0, path);
    for (const item of items) assert.ok(item.includes(words), `${path}: ${item}`);
  }
  assert.ok(read("Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionPrompts.swift").includes(words));
  assert.ok(read("Go/internal/agentsd/changes.go").includes(`"${words}"`));
});
