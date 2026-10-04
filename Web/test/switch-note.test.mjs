// PoolWords.switchNote on the page (#252): the headline, then what was carried, handed over,
// left out, and how it is paid for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { switchNote, runtimeName } = await load("src/model/switchNote.ts");
const record = (more) => ({ id: "s", at: 0, agentID: "a", from: { runtimeID: "claude" }, to: { runtimeID: "codex" },
  reason: "rateLimitPersisted", carried: [], dropped: [], billing: { allowance: {} }, ...more });

test("the catalog's names, else the id as written", () => {
  assert.equal(runtimeName("opencode"), "OpenCode");
  assert.equal(runtimeName("somebody-new"), "somebody-new");
});

test("a headline and the hand-over line", () => {
  assert.deepEqual(switchNote(record({})), { headline: "Claude stayed rate limited. Carried on with Codex.",
    lines: ["Given the whole conversation so far, and your last message again."] });
  assert.deepEqual(switchNote(record({ reason: "byHand" })).lines, ["Codex is given the conversation so far with your next message."]);
});

test("carried settings, a shortened hand-over, what was left out, and paying", () => {
  const note = switchNote(record({
    carried: [{ optionID: "model", name: "Model", to: "gpt-5", source: { level: { _0: "Deep" } } },
      { optionID: "mode", name: "Mode", to: "ask", source: { strictestMode: {} } },
      { optionID: "x", name: "Ignored", to: 3, source: { person: {} } }],
    shortened: 4,
    dropped: [{ alwaysAllow: { count: 2 } }, { queuedSlashCommand: { _0: "/review" } }],
    billing: { freeTier: { reset: { dailyAt: { hour: 0, timeZone: "UTC" } } } },
  }));
  assert.deepEqual(note.lines, [
    "Model: gpt-5, from your “Deep” level · Mode: ask, Codex’s strictest",
    "Given the whole conversation so far, and your last message again.",
    "The conversation was too long to hand over whole: 4 earlier turns were left out.",
    "Not carried: 2 “always allow” answers, so Codex may ask again; a queued /review, which Codex does not have; it is held until you edit it.",
    "Now on Free tier · resets daily.",
  ]);
});
