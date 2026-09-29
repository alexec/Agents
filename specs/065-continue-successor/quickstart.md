# Quickstart: Read Another Session's History

Use a scratch root. Steps that need a runtime to refuse are run by the tests named with them,
against the fake runtime; the rest are walked on a scratch app. A real Claude turn on a small
model is fine; do not spend credit on purpose.

## Session history

1. Create two sessions in one project with distinct titles. Include a user request, an agent
   reply, a tool call with a file path and a plan update in the source session.
2. From the second session, call `list_sessions` and check both sessions are listed with their
   ids, runtime names, status and last activity. Confirm `lastSaid` is omitted when unavailable.
3. Call `read_session` by the source id, then by its exact title. Confirm the readable history
   contains the request, reply, tool activity and last plan.
4. Compare the source agent record, transcript, activity time and status before and after the
   read; all remain unchanged.
5. Check duplicate titles return the match list, unknown titles return the not-found sentence,
   retired sessions return the gone sentence, and another project's id is indistinguishable
   from a missing id.
6. Repeat from a helper agent. It can list and read the same project but cannot name another
   project.
7. Build a history over 80,000 characters. Check the first request and plan remain, newest
   complete turns are retained, and the omission count is correct.

## Allowance ending

By `AllowanceEndingTests`, `RateLimitStreakTests` and `InChatRefusalTests`; the status and
stop mark by `SpentAllowanceGroupTests`, and on screen with a planted record.

1. Have a fake runtime return a recognized spent-allowance result during a turn.
2. Check the chat stays on the same runtime, receives the allowance note and **Its allowance
   ran out** status, and has no pending carry or allowance wait.
3. Check `runtimes/allowances` shows that runtime out, with a check four hours on.
4. Start or prompt a second chat on the same runtime. The prompt bar warns before its first
   message; the prompt is sent anyway. When its turn works, the runtime is available again.
5. Return a short rate limit and check the same chat retries on the same runtime according to
   the existing delay policy.

## Runtime state without a pool

Steps 3 and 4 by `RuntimeStateTests` and `GeminiFreeTierTests`; the rest walked. Seed as in the `keep-pool-known` walk: `pool/applyAllowances` with `since` at least four hours
ago, since a later one is moved forward. No pool is set up.

1. Open **Settings ▸ Agent Runtimes**. The seeded runtime's card says **Out · checking after
   ‹time›**, with **Mark available**.
2. Wait for the heartbeat. `daemon.log` has `availability check for ‹runtime›: passed (mode …, model …)`, and
   the card says **Available**.
3. Fail a fake runtime with an unrecognised error. Its card says it failed, with its next check.
4. Have a fake Gemini refuse with Google's credit-used-up words. Its card says **Credit used
   up · checking after ‹time›**; there is no Add credit anywhere.
5. With an out runtime from before the update in `allowances.json`, relaunch: it is still out,
   with the same next check.

## Compatibility and removal

1. Open a transcript containing old pool-switch, handoff and settings-changed entries; all
   entries still decode and draw.
2. Open an agent record containing legacy pool fields and an allowance wait. It decodes, the
   wait is cleared without starting a turn, and the standalone blocked-chat **Carry on** remains.
3. On Mac, iPhone and iPad, confirm the Pool page, Pool settings, Continue with, Matching
   models and allowance-wait status are absent, and that Spending on the phone has Runtimes.
4. Launch with an old `pool.json` and `allowances.json` on disk. The pool is not read; the
   runtimes out in `allowances.json` are still out.
