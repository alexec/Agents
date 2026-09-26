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
