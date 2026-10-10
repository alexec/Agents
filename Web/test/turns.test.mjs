// The chat's fold, its turns and a tool call's line, as Swift has them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";
import { digest } from "./digest.mjs";

const turns = await load("src/model/turns.ts");


for (const { name, input, expected } of cases("turns/transcripts.json")) {
  test(`fold: ${name}`, () => {
    const items = turns.display(input.entries);
    const all = turns.turns(items);
    assert.deepEqual({
      items: items.map(digest),
      omittingThoughts: turns.omittingThoughts(items).map((i) => i.id),
      turns: all.map((turn, index) => {
        const live = input.isLive && index === all.length - 1;
        const parts = turns.turnParts(turn.items, live);
        const outcome = new Set(parts.outcome.map((i) => i.id));
        return {
          id: turn.id,
          ask: turn.ask?.id ?? null,
          outcome: parts.outcome.map((i) => i.id),
          stepCount: parts.stepCount,
          live: parts.live?.id ?? null,
          steps: turns.drawnInTurn(turn.items, live).filter((i) => !outcome.has(i.id)).map((i) => i.id),
        };
      }),
    }, expected);
  });
}

for (const { name, input, expected } of cases("turns/lines.json")) {
  test(`line: ${name}`, () => {
    assert.deepEqual({ turnLine: turns.turnLine(input.call), line: turns.callLine(input.call) }, expected);
  });
}

test("copy takes the whole message as written (#519)", () => {
  const agent = (text, blocks) => ({ id: "a", at: "", kind: { agentMessage: { messageID: "m", text, blocks } } });
  assert.equal(turns.copiedText(agent("## Done\n\n- one\n- `two`")), "## Done\n\n- one\n- `two`");
  assert.equal(turns.copiedText({ id: "u", at: "", kind: { userMessage: { _0: "Fix it", blocks: [] } } }), "Fix it");
  // Blocks alone give the text in them.
  assert.equal(turns.copiedText(agent("", [{ type: "text", text: "a" }, { type: "text", text: "b" }])), "ab");
  // Nothing to copy is nothing offered.
  assert.equal(turns.copiedText(agent("")), undefined);
  assert.equal(turns.copiedText({ id: "n", at: "", kind: { runtimeNote: { _0: "note" } } }), undefined);
});
