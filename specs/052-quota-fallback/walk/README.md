# 052 walk log

## Baseline (T001, T002), 2026-09-26

- Merged `main` into `agents/052-quota-fallback` at `0dc9fab`. `git merge-base --is-ancestor main HEAD` holds.
- On main, as the plan assumes: `runtimeError` (049), `usageLimit` (046), `quotaUsage` (046),
  `CredentialKind.openAIAPIKey` (047) and `.geminiAPIKey` (046) are all there.
- `swift test` in `Packages/AgentsKit`, run twice on `0dc9fab` in a detached worktree: **2337
  tests in 272 suites, all passed**, both runs (52 s and 35 s). Any later failure is this lane's
  only if it is new, and only after six runs on both commits.

## Slices 1 and 2 (T003–T023), 2026-09-26

- Slice 1 committed `9b7e375`: typed failures asked for, read, said, and never finished.
- Slice 2: recognition, allowance state, the stores and the words. A plan window arrives by
  `usage_update` and the turn's answer by the prompt's reply, and the answer can arrive
  first, so the window is carried on `TurnResult.rateLimit` as well (found by
  `AllowanceRecognitionTests` failing once, then fixed).
- Found in 049's tests: Antigravity's quota refusal is already captured ("Resource has been
  exhausted (e.g. check quota)."). It is treated as a rate limit that counts as spent after
  three in ten minutes, because Google uses the same words for both. Research R13 updated.
- Full suite on this branch, three runs: 2403 tests. Two passed clean; one failed only
  `theSettlingPauseIsNotStartedAgainByARestart`, which is on the `FlakyUnderLoad` list and
  passes alone. Before a fix, a slice-1 test left a 30 s rate-limit retry running after it
  ended, and the extra load failed `aQuietDirectLinkLosesAfterTheWindow` (also on the list)
  and `aPhoneThatComesStraightBackIsKnownAgain`. That test now retries nothing.
- T005 (the stand-in runtime executable) is deferred to the look gate, where it is first
  needed; nothing before it runs outside `swift test`.

## Look gate (T024–T032), 2026-09-26

Built against `scripts/seed-pool.py` on `/tmp/run-052-look` (the wireframes' moment, seeded as
files; the real Codex toolset linked in read-only so discovery finds it). Screenshots in
`walk/look/`:

1. `1-pool-page.png`: the sidebar's Pool row with its dot and count line; runtimes in order
   with payment capsules and state lines; Mark available on the two that are out; the prepaid
   key's "≈ $3.20 of $10.00 used"; Matching models; recent switches linking to their chats.
2. `2-chat-switch-note.png`: the tinted switch note (headline with return time, model and
   mode with where each came from, what was handed over, what was not carried, the two links)
   and the folded handoff.
3. `3-continue-with-menu.png`: the prompt bar's runtime control, with the per-chat tick, the
   pool's runtimes with their states, and Grok "not in the pool".
4. `4-continue-with-sheet.png`: the sheet's four columns and Won't carry over. Its right-hand
   column is a placeholder ("Claude's default") until the carry rules land in US1/US5, and
   Continue is disabled.

Not captured: Settings ▸ Pool and the Add credit sheet. Pressing a Settings tab through the
accessibility tree walks every menu and took over 40 s, so it was stopped. Both build and are
there to open by hand. Found and fixed on the way: times came out on a 12-hour clock with no
AM/PM (now the Mac's own setting); the switch note did not draw from seeded data, because a
record inside a transcript entry keeps dates as numbers, which the seed now does too; the shared
switch note used a macOS-only link style (the Remote now builds too).

Still to do from T026: the "⇄ Carried on from …" line on the agent row.
