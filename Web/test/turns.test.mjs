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

test("a waiting card is placed where it was asked, as Swift's placing (#973)", () => {
  const ask = (id, at) => ({ kind: "entry", id, entry: { id, at, kind: { userMessage: { _0: id, blocks: [] } } } });
  const said = (id, at) => ({ kind: "entry", id, entry: { id, at, kind: { agentMessage: { messageID: id, text: id, blocks: [] } } } });
  const run = (id) => ({ kind: "run", id, calls: [] });
  const shape = (stretches) => stretches.map((s) => ({
    turns: s.turns.map((t) => [...(t.ask ? [`[${t.ask.id}]`] : []), ...t.items.map((i) => i.id)]),
    cards: s.cards.map((c) => c.name),
  }));
  const rows = turns.turns([ask("A", 0), said("a1", 1), run("r"), said("a2", 6), ask("B", 10), said("b1", 11)]);
  // None waiting: the conversation as it is.
  assert.deepEqual(shape(turns.placing(rows, [], (c) => c.at)), [{ turns: [["[A]", "a1", "r", "a2"], ["[B]", "b1"]], cards: [] }]);
  // Mid-turn, after the run that raised it; a later turn whole below; newer than everything at the end.
  assert.deepEqual(shape(turns.placing(rows, [{ name: "allow", at: 3 }, { name: "keep", at: 8 }, { name: "z", at: 20 }], (c) => c.at)), [
    { turns: [["[A]", "a1", "r"]], cards: ["allow"] },
    { turns: [["a2"]], cards: ["keep"] },
    { turns: [["[B]", "b1"]], cards: ["z"] },
  ]);
  // Older than everything: at the top. Two at one place: together, in the order given.
  assert.deepEqual(shape(turns.placing(rows, [{ name: "x", at: -5 }, { name: "y", at: -1 }], (c) => c.at)), [
    { turns: [], cards: ["x", "y"] },
    { turns: [["[A]", "a1", "r", "a2"], ["[B]", "b1"]], cards: [] },
  ]);
});

test("a question's own record, a moment after it, stays above its card (#973)", () => {
  const said = (id, at) => ({ kind: "entry", id, entry: { id, at, kind: { agentMessage: { messageID: id, text: id, blocks: [] } } } });
  const rows = turns.turns([said("a1", 1), said("asked", 3.002), said("a2", 9)]);
  const stretches = turns.placing(rows, [{ at: 3 }], (c) => c.at);
  assert.deepEqual(stretches.map((s) => s.turns.flatMap((t) => t.items.map((i) => i.id))), [["a1", "asked"], ["a2"]]);
});
