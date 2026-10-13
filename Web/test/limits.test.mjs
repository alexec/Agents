// Token limits beside the money ones (#838), held to the same rules as Agent.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const l = await load("src/model/limits.ts");
const ran = (over) => ({ id: "a", state: "finished", createdAt: 1, lastActivityAt: 2, ...over });
const usage = (input, output, extra = {}) => ({ totalTokens: input + output, inputTokens: input, outputTokens: output, ...extra });

test("limits: a cache read is not counted, wherever the runtime puts it", () => {
  assert.equal(l.limitTokens(usage(200, 100, { cachedReadTokens: 1000, totalTokens: 1300 })), 300);
  assert.equal(l.limitTokens(usage(1200, 100, { cachedReadTokens: 1000 })), 300);
  assert.equal(l.limitTokens(usage(200, 100, { cachedWriteTokens: 50, totalTokens: 350 })), 350);
});

test("limits: an agent at its token ceiling is at its limit; one with no tokens never is", () => {
  const limits = { perAgentTokens: 1000 };
  assert.ok(l.isAtTokenLimit(ran({ tokensToDate: 1000, lastTurnUsage: usage(10, 0) }), limits));
  assert.ok(!l.isAtTokenLimit(ran({ tokensToDate: 999, lastTurnUsage: usage(10, 0) }), limits));
  assert.ok(!l.isAtTokenLimit(ran({}), { perAgentTokens: 0 }), "Codex reports no tokens");
  assert.equal(l.tokenFigure(ran({ tokensToDate: 400, lastTurnUsage: usage(10, 0) }), limits), `${(400).toLocaleString()} of ${(1000).toLocaleString()} tokens`);
});

test("limits: going on steps only the limit it reached", () => {
  const agent = ran({ tokensToDate: 1200, lastTurnUsage: usage(10, 0) });
  assert.deepEqual(l.goOnRequest(agent, { perAgentTokens: 1000 }), { agentID: "a", tokenCeiling: 2200 });
  assert.deepEqual(l.goOnRequest(ran({ costToDate: { USD: 3 } }), { perAgent: { amount: 2, currency: "USD" } }),
    { agentID: "a", ceiling: { amount: 5, currency: "USD" } });
});

test("limits: the day's token limit is reached on the same word as the money", () => {
  assert.ok(l.dayTokenLimitReached({ limits: { dailyTokens: 100 }, tokensToday: 100, today: {}, day: "" }));
  assert.ok(!l.dayTokenLimitReached({ limits: { dailyTokens: 100 }, tokensToday: 99, today: {}, day: "" }));
  assert.ok(!l.dayTokenLimitReached({ limits: {}, tokensToday: 1e9, today: {}, day: "" }));
});
