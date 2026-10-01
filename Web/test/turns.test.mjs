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
