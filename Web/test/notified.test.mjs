// What an agent told the person with `notify` (#2805): drawn at every level, as SentNotice.swift
// says what became of it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const turns = await load("src/model/turns.ts");
const notified = await load("src/model/notified.ts");

test("a notice stands on its own, after the run that called it, at every level", () => {
  const call = (id, n) => ({ id, at: n, kind: { toolCall: { _0: { toolCallID: `c${n}`, title: "notify", kind: "other" } } } });
  const entries = [
    { id: "u", at: 0, kind: { userMessage: { _0: "Deploy it" } } },
    call("t1", 1),
    { id: "n", at: 2, kind: { notified: { _0: { title: "The deploy finished", outcome: "sent" } } } },
  ];
  const items = turns.display(entries);
  assert.deepEqual(items.map((i) => i.kind === "run" ? `run:${i.calls.length}` : i.id), ["u", "run:1", "n"]);
  const [turn] = turns.turns(items);
  assert.deepEqual(turns.turnParts(turn.items, false).outcome.map((i) => i.id), ["n"]);
});

test("it says what became of the notice", () => {
  assert.equal(notified.noticeOutcome({ title: "t", outcome: "sent" }), "Sent");
  assert.equal(notified.noticeOutcome({ title: "t", outcome: "shownHere" }), "Shown here");
  assert.equal(notified.noticeOutcome({ title: "t", outcome: "muted" }), "Muted: not sent");
  assert.match(notified.noticeOutcome({ title: "t", outcome: "coolingDown", nextAt: 0 }), /^Not sent: the next notice can go at /);
});

// Where it went (#2860) is said on its line, and is no line of its own.
test("where a notice went is said on its line", () => {
  const entries = [
    { id: "n", at: 2, kind: { notified: { _0: { title: "The deploy finished", outcome: "sent" } } } },
    { id: "d", at: 3, kind: { noticeDelivered: { _0: { notice: "n", to: "iPhone" } } } },
  ];
  const items = turns.display(entries);
  assert.deepEqual(items.map((i) => i.id), ["n"]);
  assert.equal(notified.noticeOutcome(items[0].entry.kind.notified._0), "Sent to iPhone");
  assert.equal(notified.noticeOutcome({ title: "t", outcome: "sent", to: "computer" }), "Sent to the computer");
  // One whose line is on an earlier page is left out.
  assert.deepEqual(turns.display([entries[1]]), []);
});
