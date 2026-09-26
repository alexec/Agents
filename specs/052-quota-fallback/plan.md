# Implementation Plan: Carry On When a Runtime Runs Out

**Branch**: `agents/052-quota-fallback` (feature `052-quota-fallback`) | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md) | **Wireframes**: [wireframes.md](wireframes.md)

**Input**: Feature specification from `specs/052-quota-fallback/spec.md`

## Summary

A chat whose runtime says its allowance is spent moves to the next entry in the person's pool.
It moves with the conversation, with its settings mapped across, and with the prompt that failed
re-sent once. Pay-as-you-go is never used: keys join the pool only on a free tier, free credit or prepaid credit, and
a runtime that starts using paid overage is treated as out.

The feature rests on one finding from reading the adapters (research R1). **The Claude and Codex
adapters already classify provider refusals for us.** They implement a shared ACP extension, the
JetBrains "AIR" session-failure extension, that tells `quota_exhausted` from `rate_limited`, but
only to a client that advertises it. The app does not advertise it today. So:

- A spent Claude plan reaches the app as a rejected prompt. The app then says "Claude stopped
  answering" and records a crash.
- With the extension advertised, and nothing else changed, the same refusal would arrive as
  `end_turn`, and the app would mark the chat **finished**.

The first slice is therefore to **read typed failures properly**, for every kind, not only
limits. That is worth doing on its own. Everything else builds on it.

Claude also reports its plan window on every `usage_update`: `resetsAt`, `rateLimitType`, and
whether paid overage has begun (R2, R3). That gives the "until 07:00" and the never-pay guard
from the vendor's own data, not from guesses.

The rest follows the patterns the app already has:

- **Pure decisions in Core.** `LimitRecognition`, `PoolPlan`, `SettingsCarry` and `Handoff` are
  tested without a daemon, as `RetentionPlan` and `ModeLooseness` are.
- **The daemon applies them.** A new `DaemonCore+Pool.swift` does so from the two places a turn
  ends today: the `TurnResult` path, and `turnFailed`.
- **Settings in daemon files.** `pool.json`, `allowances.json` and `switches.jsonl` sit beside
  `limits.json`, and are pushed to servers the same way (R6).
- **One timer for waiting.** An everyone-out wait uses the due-timer that resumes blocked agents
  (R8).
- **The handoff.** It is a Markdown document built from the app's own transcript. It is sent as
  an embedded resource ahead of the re-sent prompt, and drawn folded under the switch note, never
  as the person's bubble (R4).

## Technical Context

**Language/Version**: Swift 6.2 (strict concurrency), macOS 27 / iOS 27; Linux `agentsd` for
servers (037)

**Primary Dependencies**: none new. ACP over JSON-RPC (existing `ACPSession`), SwiftUI for the
Mac and the Remote

**Storage**: daemon files under the store root: `pool.json`, `allowances.json`,
`switches.jsonl` (R6). The agent record gains four fields (data-model).

**Testing**: Swift Testing in `Packages/AgentsKit/Tests`. `FakeACPAgent.Script` is extended with
prompt-result `_meta`, `usage_update` `_meta`, and "fail N times then succeed". There is a new
`fake-acp-runtime` executable for scratch-app walks (quickstart).

**Target Platform**: the Mac app and daemon; the Remote, which gets a read-mostly Pool page;
Linux `agentsd`, where entries are judged per host.

**Project Type**: desktop app, with a daemon and a phone companion

**Performance Goals**:

- A switch starts the new runtime within 30 s of the refusal (SC-001). It adds one handshake, one
  `session/new`, and a prompt whose handoff is at most 400 k characters.
- `pool/changed` is debounced to one per second.

**Constraints**:

- **Never switch on a guess** (FR-006).
- **Never let a refused turn read as finished** (R1).
- **No tight polling of the socket or of providers.** See the memory note
  `daemon-socket-polling-exhausts-descriptors`.
- **No new timers.** Waiting uses the existing due-timer (R8).
- **Keep the app's window modifier chain as it is.** See the memory note
  `scratch-app-opens-no-window`.

**Scale/Scope**:

- 7 catalogue runtimes on main as of 2026-09-26: Claude, Grok, Copilot, Cursor, Codex (047, with
  its server relay), Gemini (046) and Antigravity (049). OpenCode and Goose are specced, but not
  built.
- One allowance state per credential, shared by the Mac and any server that relays the same plan
  (R6).
- Pools of 2–8 entries.
- Up to hundreds of chats on one entry.
- 30 days of switches.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
principles to check against. In their place, the plan is checked against the project's standing
rules (CLAUDE.md, memory):

| Rule | How 052 meets it |
|---|---|
| Settle the UX before depth | Wireframes were done and agreed before this plan. Slice order (below) puts the visible note and page early. |
| Main checkout is only main | All work is in `.agents/worktrees/052-quota-fallback`. Merge only when Alex says. |
| Test on a scratch root, never the real app | The quickstart runs only on a scratch root with stand-in runtimes. Real runtimes get read-only checks. |
| Never mutate source to prove a test | The fake runtime is scripted by a file and an environment variable, not by editing code. |
| Suite is flaky under load | Done means six full runs compared with main. |

**Result: pass.** Re-checked after Phase 1: still pass. The one new executable is test-only.

## Project Structure

### Documentation (this feature)

```text
specs/052-quota-fallback/
├── spec.md
├── wireframes.md, wireframes/*.svg
├── plan.md              # this file
├── research.md          # R1–R13
├── data-model.md
├── contracts/
│   ├── daemon-api.md
│   └── acp-session-failure.md
├── quickstart.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── ACP/
│   ├── ACPTypes.swift              # clientCapabilities._meta gains the AIR sessionFailure capability
│   ├── SessionFailure.swift        # NEW: decode _meta.jetbrains.air.sessionFailure, _claude/rateLimit
│   └── SessionUpdate.swift         # session_info_update with a failure; usage_update keeps _meta
├── Model/
│   ├── Agent.swift                 # poolEntryID, switchingOff, allowanceWait, triedForPrompt
│   ├── EndedReason.swift           # allowanceSpent, rateLimited (R11)
│   ├── TranscriptEntry(+Coding).swift  # poolSwitch, handoff, settingsChanged
│   └── EventCatalogue.swift        # agent.runtime_switched, cost.allowance_out/back
├── Pool/                           # NEW folder
│   ├── PoolSettings.swift          # PoolEntry, Payment, Level, validation
│   ├── AllowanceState.swift        # Status, transitions, ledger
│   ├── LimitRecognition.swift      # classify(); word lists per runtime; RateLimitPolicy
│   ├── PoolPlan.swift              # next(for:…)
│   ├── SettingsCarry.swift         # CarryPlan, using ModeLooseness and ModeMemory
│   ├── Handoff.swift               # document(entries:budget:)
│   └── PoolStatus.swift            # the page's derived view and row words, shared Mac + phone
└── Daemon/DaemonAPI.swift          # pool/*, agents/continueWith, agents/setSwitching

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/ACPSession.swift            # TurnResult.failure; keep the latest rateLimit info
├── Daemon/
│   ├── DaemonCore+Pool.swift       # NEW: apply recognition, switch, wait, ledger, events
│   ├── DaemonCore+Commands.swift   # turnFailed and the turn-result path hand to +Pool; finished guard
│   ├── DaemonCore+Blocks.swift     # due-timer also resumes allowance waits
│   └── DaemonCore+Runtimes.swift   # freshSession reused for the new runtime
└── Store/StoreLocations.swift      # pool.json, allowances.json, switches.jsonl

App/Sources/
├── Projects/ProjectListView.swift  # Pool row in Activity with its dot
├── Pool/                           # NEW: PoolPage, MatchingModelsGrid, AddCreditSheet
├── Chat/PromptBar.swift            # runtime control becomes the Continue with menu
├── Chat/ContinueWithSheet.swift    # NEW
├── Transcript/                     # switch note, folded handoff
└── Settings/PoolSettingsView.swift # NEW tab, between Spending and Devices

Remote/Sources/
└── Pool/                           # NEW: the page, a level's detail, swipe to mark available

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/LimitRecognitionTests.swift, PoolPlanTests.swift, SettingsCarryTests.swift,
│   HandoffTests.swift, PoolSettingsTests.swift, SessionFailureDecodingTests.swift
├── Integration/PoolSwitchTests.swift, AllowanceWaitTests.swift, ContinueWithTests.swift,
│   TypedFailureNeverFinishesTests.swift
└── Fake/FakeACPAgent.swift         # Script: promptResultMeta, usageMeta, failThenSucceed
Tools/fake-acp-runtime/             # NEW, test-only executable for scratch walks
docs/how-to/keep-going-when-a-runtime-runs-out.md, docs/reference/{settings,runtimes,events,statuses}.md
```

**Structure Decision**:

- Decisions go in `AgentsKitCore/Pool/`, a new folder beside `Runtimes/`, because the phone
  draws the same words.
- The daemon glue goes in one new extension file, like every other daemon concern.
- The UI gets one new folder each on the Mac and the Remote.
- Nothing moves.

## Slices (for /speckit-tasks)

Each slice can be merged on its own, and each is visible when it lands.

1. **Typed failures, read properly.** This slice does four things:
   - advertise the capability;
   - decode the failure on the turn result and on the session update;
   - never mark a failed turn as finished;
   - write every failure's title into the chat.

   The finished guard sits beside the `result.runtimeError` branch that 049 added in the
   turn-result path of `DaemonCore+Commands.swift`: a typed error failure is handled the same way,
   with its own note, and never reaches `finished`. Also add the two `EndedReason` cases, used
   when there is no pool. On its own, this ends
   "Claude stopped answering" for a spent plan. It needs a real-runtime read-only check (quickstart
   §10).
2. **Recognition, and allowance state.** `LimitRecognition` (all three layers), `AllowanceState`,
   `allowances.json`, the rate-limit retry, and the overage guard. Still no switching: the chat
   stops with *Out until 07:00*.
3. **The pool and the automatic switch.** `pool.json`, `PoolPlan`, `SettingsCarry` (without the
   grid), `Handoff`, `DaemonCore+Pool`, the switch note, events, and `switches.jsonl`. This is the
   P1 feature.
4. **Settings ▸ Pool, and the Pool page (Mac).** Credit entries, and the Add credit sheet.
5. **Continue with, and Matching models.** The sheet, the grid, Remember, and adjusting after a
   switch.
6. **Everyone out.** The wait, and resuming.
7. **The phone and servers.** The Remote page, pushing settings to hosts, and per-host state.
8. **Docs.**

## Risks

- **Advertising the extension changes adapter behaviour.** Claude drops the raw detail from
  internal errors. Slice 1 exists so that nothing is lost, and its tests cover every kind in
  the policy table.
- **Adapter drift.** The extension is versioned (`version: 1`). Decoding tolerates unknown
  categories and actions, and treats them as "no switch". The toolset pins its versions. A bump
  must re-run quickstart §10.
- **Codex rate-limit data may not be forwarded** (R2). The fallbacks are the failure title, then
  the one-hour rule. Neither blocks the feature.
- **EndedReason.** Both of the other lanes' cases are on main now (R11), so there is no clash
  left. 052 adds its two cases beside `runtimeError`, and the `allCases` test covers them.
- **Antigravity's quota wording is not captured yet** (R13). Until it is, Antigravity cannot be
  switched away from automatically. The unrecognised-refusal log line (R1, layer 3) is how it
  gets captured.
- **Handoff quality** (SC-004). It depends on the new runtime reading a long document well. The
  budget and the keep-first-and-latest rule are tunable constants, and SC-004 is measured by hand
  on real test conversations before release.

## Complexity Tracking

No constitution violations to justify. One piece of complexity is deliberate: the test-only
`fake-acp-runtime` executable. The simpler alternative, testing only in-process with
`FakeLauncher`, cannot prove the Mac window's note, page and sheet. The memory note on the
`run-app` skill says to never hand Alex a walk that could be run instead.
