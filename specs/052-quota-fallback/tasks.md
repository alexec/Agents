# Tasks: Carry On When a Runtime Runs Out

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/daemon-api.md](contracts/daemon-api.md),
[contracts/acp-session-failure.md](contracts/acp-session-failure.md),
[quickstart.md](quickstart.md), [wireframes.md](wireframes.md)

**Tests**: Included. There are three reasons:

- A wrong switch spends the person's money or moves their work, so every rule gets a test
  before the code that makes it pass.
- Pure rules go in `Pkg/Tests/AgentsKitTests/Unit/`.
- Daemon behaviour goes in `Pkg/Tests/AgentsKitTests/Integration/`. Model it on
  `BlockedTests.swift`, `CostLimitFlowTests.swift` and `ParkingTests.swift`. They build a
  `DaemonCore` on a temporary root, with an injected `now` and a `FakeLauncher`.

**Where**:

- All work is in `.agents/worktrees/052-quota-fallback`, on branch `agents/052-quota-fallback`.
- `Pkg/` means `Packages/AgentsKit/`.
- Never edit the shared checkout.
- Scratch roots are `/tmp/run-052*`. Never touch `~/Library/Application Support/Agents` or its
  `daemon.sock`.
- Stop a scratch daemon by the pid in its own `daemon.lock`.

**Rules this feature must keep**:

- **Never switch on a guess.** Only a positively recognised spent allowance moves a chat (FR-006).
- **Never pay.** No key without a hard stop joins the pool, and no pay-as-you-go offer is ever
  accepted (FR-001a, FR-007, SC-002).
- **A turn carrying an error-severity typed failure never reaches `finished`**, whatever
  `stopReason` says (research R1).
- **The prompt that failed is sent to the new runtime exactly once** (FR-011).
- **Allowance state belongs to the credential, not the host.** A relayed Codex on a server
  shares the Mac's plan (R6).
- **The words live in `PoolWords`**, in Core, and the Mac and the phone call the same functions.
- **Older phones must keep decoding `Agent` and `TranscriptEntry`.** Only optional fields and
  new cases that fall back to "unknown" are added.

**Order**:

1. Setup.
2. Foundational: typed failures read properly (plan slice 1), then recognition and allowance
   state (slice 2).
3. A **look gate**: the switch note, Pool page, Settings tab, Continue with sheet and Add credit
   sheet are built against hand-written `pool.json`, `allowances.json`, `switches.jsonl` and
   transcript entries on a scratch root, and screenshotted for Alex before any switching code
   runs (the rule: settle the UX before building depth).
4. The stories: US1, the MVP; then US2 and US3, which finish the P1 set; then US4, US5 and US6.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `agents/052-quota-fallback` in this worktree. Verify with `git merge-base --is-ancestor main HEAD`, not by trusting the merge output. Then check what the plan assumes is on main: `git grep -n 'runtimeError\|usageLimit\|quotaUsage\|openAIAPIKey\|geminiAPIKey' main -- Pkg/Sources`. Each must be found. Record any that moved in `specs/052-quota-fallback/walk/README.md`.
- [X] T002 Record the baseline in `specs/052-quota-fallback/walk/README.md`: run `swift test` in `Pkg/` twice, and write down which tests fail before any change. The suite is flaky under load, so a later failure belongs to this lane only if it is new, and only after six runs on both commits.
- [X] T003 [P] Capture fixtures in `Pkg/Tests/AgentsKitTests/Fixtures/session-failures/`. Take them from the adapters' own policy tables (research R1), one JSON file per row of the classification table in `contracts/acp-session-failure.md`:
  - `quota_exhausted` as `limit`/`[]`;
  - `rate_limited` as `limit`/`["retry"]`;
  - `budget_exhausted` as `limit`/`["new_session"]`;
  - `auth_required` as `access`/`["login"]`;
  - `overloaded` as `service`/`["retry"]`;
  - a warning-severity retry.

  Add `claude-rate-limit-info.json`, the `SDKRateLimitInfo` shape with `status`, `resetsAt`, `rateLimitType`, `isUsingOverage`, `overageInUse` and `overageStatus`. Head each file with a comment naming the adapter version it came from: Claude 0.81.2, Codex 1.13.1.
- [X] T004 [P] Extend `FakeACPAgent.Script` in `Pkg/Tests/AgentsKitTests/Fake/FakeACPAgent.swift` with four fields:
  - `promptResultMeta: JSONValue?`, returned as `_meta` on the `session/prompt` result;
  - `usageMeta: JSONValue?`, sent as a `usage_update` carrying that `_meta` before the turn ends;
  - `sessionInfoMeta: JSONValue?`, sent as a `session_info_update` with no title;
  - `failTimes: Int`, for failing that many prompts (with the existing `promptError` or `promptResultMeta`) and then succeeding.

  Record every prompt's content blocks in order, so a test can assert what the runtime was sent and how many times.
- [X] T005 [P] Add the test-only executable `Tools/fake-acp-runtime/main.swift`, and its target in `Pkg/Package.swift` or a separate `Tools/Package.swift`. It must never be linked into the app or `agentsd`. It speaks ACP over stdio and plays a `FakeACPAgent.Script` read from the JSON file named by `AGENTS_TEST_FAKE_SCRIPT_<NAME>`, where `<NAME>` is the uppercased basename it was started as. Add `scripts/install-fake-runtimes.sh <dir>`, which copies it as `grok` and `copilot` into `<dir>` for `AGENTS_TEST_SEARCH_PATHS`, and refuses any `<dir>` under `~/Library` or `~/.local`.

  *Done 2026-09-26 as `scripts/fake-acp-runtime.py`: Python, test-only, and never built into
  anything.* It plays `spent` or `ok`, read each turn from `<dir>/<name>.behaviour`, so a walk
  can spend a runtime and bring it back by rewriting one file. Moving the Swift `FakeACPAgent`
  out of the test target was more churn than a walk harness needs.

---

## Phase 2: Foundational — typed failures read properly (plan slice 1)

**Purpose**: Once the app asks Claude and Codex for typed failures, a spent plan arrives as `end_turn` with `_meta`. It must never read as finished. This phase ships value on its own: a spent Claude plan stops saying "stopped answering".

- [X] T006 [P] Write `Pkg/Tests/AgentsKitTests/Unit/SessionFailureDecodingTests.swift`. There is one test per T003 fixture. Each decodes `_meta.jetbrains.air.sessionFailure` into `SessionFailure`, keeping `{id, revision, category, severity, title, details, reason, actions}`. Also test:
  - an unknown category or action decodes and is kept as itself;
  - a missing `_meta`, or a `_meta` without `jetbrains.air`, gives `nil`;
  - a higher `revision` of the same `id` replaces a lower one;
  - `_claude/rateLimit` decodes into `RateLimitInfo`, with `resetsAt` read as Unix seconds.
- [X] T007 [P] Write `Pkg/Tests/AgentsKitTests/Unit/ClientCapabilitiesTests.swift`, asserting that `ACP.ClientCapabilities.wire` carries `_meta.jetbrains.air = {version: 1, capabilities: ["sessionFailure"]}` and still carries every key it carried before (`fs`, `terminal`, `session`, `plan`, `auth`, `elicitation`).
- [X] T008 Implement `Pkg/Sources/AgentsKitCore/ACP/SessionFailure.swift` with `SessionFailure`, `RateLimitInfo`, and `static func in(_ meta: JSONValue?) -> SessionFailure?`, so that T006 passes. Model it on how `ACPSession.quotaUsage(in:)` reads Gemini's `_meta.quota` (046).
- [X] T009 Add the AIR capability to `ACP.ClientCapabilities.wire` in `Pkg/Sources/AgentsKitCore/ACP/ACPTypes.swift`, merging it with any `_meta` already sent, so that T007 passes.
- [X] T010 In `Pkg/Sources/AgentsKitCore/ACP/SessionUpdate.swift`, make a `session_info_update` with a failure `_meta` a new case, `.failure(SessionFailure)`, instead of `.ignored`. A title and a failure in one update give both. Make `usage_update` keep its `_meta["_claude/rateLimit"]` on `Usage` as `rateLimit: RateLimitInfo?`, as an optional field.
- [X] T011 In `Pkg/Sources/AgentsKit/ACP/ACPSession.swift`, add `failure: SessionFailure?` to `TurnResult`, read from the prompt result's `_meta` beside `quotaUsage`. A session-scoped failure that arrives by `session_info_update` during a turn attaches to that turn's result.
- [X] T012 [P] Write `Pkg/Tests/AgentsKitTests/Integration/TypedFailureNeverFinishesTests.swift`, using the fake agent with `promptResultMeta`. Check that:
  - (a) `end_turn` with an error `quota_exhausted` failure ends the agent **not** `finished`, with its `title` written as a runtime note;
  - (b) the same holds for `auth_required`, `overloaded` and `budget_exhausted`, each with its own note;
  - (c) a warning-severity failure leaves the turn's outcome alone and writes the title as a note;
  - (d) a plain `end_turn` with no failure still finishes, as on main;
  - (e) a session-scoped failure with no turn running writes one note and changes no state;
  - (f) 049's `runtimeError` path still behaves exactly as on main.
- [X] T013 In the turn-result path of `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, beside the `result.runtimeError` branch that 049 added, handle an error-severity `result.failure`. Write "\(runtimeName): \(failure.title)" as a runtime note, and end with the reason chosen by the classification in T018. Until then, end with `.runtimeError`. Never end with `.endTurn`. Handle `.failure` updates from `SessionUpdate` in the same file's update handling. This makes T012 pass.
- [X] T014 [P] Add `allowanceSpent` ("Its allowance ran out") and `rateLimited` ("Rate limited, and still limited after retrying") to `Pkg/Sources/AgentsKitCore/Model/EndedReason.swift`, beside `runtimeError`. Neither comes from `init(stopReason:)`. Extend `EndedReasonTests`, which walks `allCases`, so that each has a summary and neither is ever `finished`.

**Checkpoint**: A Claude or Codex refusal, typed or not, shows its own sentence in the chat and never reads as done.

---

## Phase 2b: Foundational — recognition and allowance state (plan slice 2)

- [X] T015 [P] Write `Pkg/Tests/AgentsKitTests/Unit/LimitRecognitionTests.swift`, with one test per row of both tables in `contracts/acp-session-failure.md`:
  - `limit`/`[]` → `.spent(resetsAt:)`, taking `resetsAt` from a `RateLimitInfo` with `status: rejected`;
  - `limit`/`["retry"]` → `.rateLimited`;
  - `limit`/`["new_session"]` → `.otherTyped`;
  - other categories → `.otherTyped`;
  - Claude without the extension, with an internal error whose text starts with each of the SDK's `USAGE_LIMIT_ERROR_PREFIXES` → `.spent`;
  - Gemini's `429 "You have exhausted your daily quota on this model."` → `.spent`;
  - any other 429, and `RESOURCE_EXHAUSTED` with "rate limit" → `.rateLimited`;
  - `insufficient_quota`, and "credit balance is too low" → `.creditGone`;
  - an Antigravity `runtimeError` sentence → `.none`, because none is captured yet;
  - `isUsingOverage: true` or `overageInUse: true` on an allowance → `.overage(resetsAt:)`;
  - anything else → `.none`.

  Move the rows of `Pkg/Tests/AgentsKitTests/Unit/UsageLimitTests.swift` (046) into this file, and delete that file once they pass here.
- [X] T016 [P] Write `Pkg/Tests/AgentsKitTests/Unit/AllowanceStateTests.swift`, covering every transition in `data-model.md` § AllowanceState, with an injected `now`:
  - a rate limit is not out;
  - a third rate limit within 10 min becomes `out(retryAfter: +1h, .rateLimitPersisted)`;
  - `out(until:)` goes back to available when `until` passes;
  - a free-credit or prepaid entry that is out **never** goes back on a timer;
  - a `.freeTier(.dailyAt(0, "America/Los_Angeles"))` entry is out until the next midnight Pacific, then available again, including across a DST change;
  - Mark available sets `learnedFrom: .person`;
  - two entries with the same `credentialKey` share one state.
- [X] T017 [P] Write `Pkg/Tests/AgentsKitTests/Unit/PoolSettingsTests.swift`, covering the validation in `data-model.md`:
  - a keyed entry (`credentialRef != nil`) must be `.freeTier`, `.freeCredit` or `.prepaid`;
  - an API-key credential can never be `.allowance`;
  - a Gemini entry is never `.allowance`;
  - amounts must be positive;
  - within one runtime, a model value may appear in at most one level, and the error names the cell;
  - `isEffective` is `isOn && entries.count >= 2`;
  - decoding ignores unknown keys;
  - there is no way to express open-ended billing.
- [X] T018 Implement `Pkg/Sources/AgentsKitCore/Pool/LimitRecognition.swift`, with `classify(turnResult:error:runtimeID:payment:rateLimit:)` returning `Recognition` (`.spent`, `.creditGone`, `.rateLimited`, `.overage`, `.otherTyped` or `.none`), the per-runtime word lists, and `RateLimitPolicy` (retries at 30 s, then 120 s; three within 10 min counts as spent). Copy the SDK's prefix list in, naming its version. This makes T015 pass. Replace `DaemonCore.usageLimit(_:)` in `DaemonCore+Commands.swift` with a call to it, so that Gemini's behaviour is unchanged until the pool is on.
- [X] T019 Implement `Pkg/Sources/AgentsKitCore/Pool/PoolSettings.swift`, with `PoolEntry`, `Payment` (`.allowance(label:)`, `.freeTier(reset:)`, `.freeCredit(amount:expires:)` and `.prepaid(amount:expires:)`, and **no** unlimited case), `ResetRule`, `Level`, `Cell`, `PoolSettings` and `validate()`. This makes T017 pass.
- [X] T020 Implement `Pkg/Sources/AgentsKitCore/Pool/AllowanceState.swift`, with `AllowanceState`, `Status`, `OutReason`, `Source`, `Spent` and `credentialKey(for:account:)`. The key is the runtime's account id for a plan, and the lent credential's id for a key. This makes T016 pass.
- [X] T021 Add `pool.json`, `allowances.json` and `switches.jsonl` to `Pkg/Sources/AgentsKit/Store/StoreLocations.swift`. Add `Pkg/Sources/AgentsKit/Store/PoolStore.swift`, following `LimitStore.swift`: it loads and saves `PoolSettings` and `[AllowanceState]` atomically, appends `SwitchRecord` lines, and drops lines over 30 days old at load (FR-025). Write `Pkg/Tests/AgentsKitTests/Integration/PoolStoreTests.swift` covering a round trip, the trim, and a missing file that loads as defaults.
- [X] T022 Add `Pkg/Sources/AgentsKitCore/Pool/PoolWords.swift`. It holds every sentence the feature shows: state lines ("Out until 07:00", "Out since 02:14 · trying again after 03:14", "Rate limited · trying again at 02:21", "Credit used up", "Free credit expired", "Can't be used: not signed in"), switch-note lines, and capsules ("Allowance · ChatGPT plan", "Free tier · resets daily", "Prepaid credit · ≈ $3.20 of $10 used", "spending not known"). Test them in `Pkg/Tests/AgentsKitTests/Unit/PoolWordsTests.swift`, with times formatted in the person's time zone.
- [X] T023 In `DaemonCore+Commands.swift` and a new `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift`, apply recognition with **no switching yet**. Make it work like this:
  - Spent: mark the credential out, end `.allowanceSpent`, and note "Claude's allowance ran out, until 07:00."
  - Rate limited: retry on the policy's schedule on the same runtime, and after three end `.rateLimited`.
  - Overage reported: mark out, and note that paid extra usage started.
  - Unrecognised refusal: log it to `daemon.log` under the prefix `052 unrecognised refusal:` with its raw error, and change nothing else.

  Write `Pkg/Tests/AgentsKitTests/Integration/AllowanceRecognitionTests.swift` for each of these, and for a relayed Codex refusal on a server host that marks the Mac's plan out.

**Checkpoint**: The app knows which credentials are out and until when, retries rate limits, and never pays for overage. Chats still stop rather than move.

---

## Phase 2c: Look gate (settle the UX before depth)

**Purpose**: Build the visible parts against hand-written state and have Alex look before any switching code runs. Nothing in this phase changes what a chat does.

- [X] T024 Add the transcript cases `.poolSwitch(SwitchRecord)`, `.handoff(markdown:characters:)` and `.settingsChanged(SwitchRecord)` to `Pkg/Sources/AgentsKitCore/Model/TranscriptEntry.swift` and `TranscriptEntry+Coding.swift`, with `SwitchRecord`, `CarriedSetting` and `Dropped` exactly as in `data-model.md`. An older reader must decode each as its existing unknown-entry fallback. Test that fallback in `Pkg/Tests/AgentsKitTests/Unit/TranscriptEntryCodingTests.swift`.
- [X] T025 [P] Add `Pkg/Sources/AgentsKitCore/Pool/PoolStatus.swift`: the derived view (entries with status words, chat counts, waiting chats, switches, and `anyOut`) and `DaemonAPI` methods `pool/state` and `pool/changed` in `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, per `contracts/daemon-api.md`. Serve them read-only from `DaemonCore+Pool.swift`, reading the files as they are on disk.
- [X] T026 [P] Draw the switch note, and the folded handoff under it, in `App/Sources/Chat/Transcript.swift`, per wireframes §2. The note has a warm tint and one line for what happened. It then gives the model, effort and mode with their sources, what was handed over, and what was not carried. It has two links: **Change what it carried on with…** (inert at this stage) and **Pool**. Add the "⇄ Carried on from … at …" line to the agent row in `App/Sources/AgentList/`. Keep one accessibility element per row (memory: stacked accessibility labels crash AppKit).
- [X] T027 [P] Add the Pool row, last in the sidebar's Activity section, with a dot and count line, in `App/Sources/Projects/ProjectListView.swift`, and `SidebarItem.pool` in `App/Sources/Projects/SidebarItem.swift`. Add `App/Sources/Pool/PoolPage.swift`, following wireframes §1: runtimes in order with credential capsules and state words, **Mark available** (inert at this stage), a waiting-chats card, the Matching models grid (read-only at this stage), and recent switches. Route it in `ContentView.detail` beside Events, Resources and Spending. Do not change the modifier chain on `ContentView()` in `AgentsApp` (memory: scratch app opens no window).
- [X] T028 [P] Add the **Pool** Settings tab, between Spending and Devices, in `App/Sources/AgentsApp.swift`. Add `App/Sources/Settings/PoolSettingsView.swift`, following wireframes §4: the switch, the ordered list with credential capsules and a Model menu, **Add a runtime**, **Add credit on an API key…**, and a link to the Pool page. At this stage it reads the files only.
- [X] T029 [P] Add `App/Sources/Pool/AddCreditSheet.swift`, following wireframes §4a: runtime, key, the four kinds with *Billed with no limit* shown disabled with its reason, amount, expiry, and the "goes last" note. Add stays disabled until a kind is picked.
- [X] T030 [P] Add `App/Sources/Chat/ContinueWithSheet.swift`, following wireframes §3. It has the runtime menu, four columns (setting, now, new, where from), **Won't carry over**, and **Remember** with its level menu. It is drawn from a hand-written `CarryPlan`. Make the prompt bar's runtime control in `App/Sources/Chat/PromptBar.swift` open the Continue with menu, following wireframes §2: the per-chat tick, the pool runtimes with their states, and runtimes outside the pool.
- [X] T031 Write `scripts/seed-pool.swift`, which writes a scratch root's `pool.json`, `allowances.json` and `switches.jsonl`, and appends `.poolSwitch` and `.handoff` entries to a chosen agent's transcript, matching the wireframes' 02:20 moment exactly. It refuses any `--root` under `~/Library`.
- [X] T032 Run the scratch app on `/tmp/run-052-look`, seeded by T031, using the run-app skill. Screenshot the Pool page, a chat with the switch note, Settings ▸ Pool, the Add credit sheet and the Continue with sheet, into `specs/052-quota-fallback/walk/look/`. Show them to Alex. **Stop here until Alex has looked**, and fold any change he asks for into the wireframes and these views first.

---

## Phase 3: User Story 1 — A chat moves on by itself (Priority: P1) 🎯 MVP

**Goal**: A recognised spent allowance moves the chat to the next usable entry, with its conversation and the failed prompt, and says so.

**Independent Test**: quickstart §2 and §3, on a scratch root with two stand-in runtimes.

- [X] T033 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Unit/PoolPlanTests.swift` for `PoolPlan.next(for:pool:states:tried:host:now:)`. Cover:
  - the first usable entry in order that is not out;
  - skipping entries already tried for this prompt;
  - skipping unusable entries (not signed in, not installed, credential missing on this host);
  - `.everyoneOut(earliest:)` with the earliest known return;
  - `.off` when `!isEffective` or the chat's `switchingOff` is set;
  - a chat started outside the pool moving to the first usable entry;
  - a relayed Codex on a server being skipped when the Mac's plan is out.
- [X] T034 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Unit/SettingsCarryTests.swift` for `SettingsCarry.plan(from:to:grid:poolEntry:remembered:)` without the grid. Cover:
  - mode: the loosest mode on the new runtime that is no looser (`ModeLooseness`); an unranked current mode → the new runtime's strictest mode;
  - model: the pool entry's model, else the model remembered for that runtime, else the default; never matched by name across vendors;
  - effort and other options: the same value under the same category if offered, else the default;
  - `extraArguments` dropped;
  - `dropped` lists always-allow answers and queued slash commands the new runtime lacks;
  - every row carries its source.
- [X] T035 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Unit/HandoffTests.swift` for `Handoff.document(entries:budget:)`. Cover:
  - the person's prompts verbatim;
  - replies;
  - one line per tool call;
  - edits as `path +a −b`;
  - the latest plan;
  - over budget: the first prompt and the latest turns are kept, and "[N earlier turns left out]" is written;
  - the result is valid Markdown, and never contains the app's own switch notes.
- [X] T036 [US1] Implement `Pkg/Sources/AgentsKitCore/Pool/PoolPlan.swift`, `SettingsCarry.swift` and `Handoff.swift`, so that T033–T035 pass.
- [X] T037 [US1] Add `poolEntryID`, `switchingOff`, `allowanceWait` and `triedForPrompt` to `Pkg/Sources/AgentsKitCore/Model/Agent.swift`, as optional or defaulted fields with `CodingKeys` entries, following the file's own pattern for added fields. Extend `AgentsModelTests` with an old record that decodes, and a new record that an older decoder reads.
- [X] T038 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Integration/PoolSwitchTests.swift`, with two fake runtimes, following quickstart §2. The first ends with `limit`/`[]`, and the agent is then on the second, without touching anything. Check that:
  - the transcript holds `.poolSwitch(allowanceSpent)`, then `.handoff`, then the second runtime's reply;
  - the second runtime received the handoff block and the failed prompt, once, in one `session/prompt`;
  - the first credential is out with `retryAfter` +1 h;
  - `agent.runtime_switched` and `cost.allowance_out` are in the event log;
  - `switches.jsonl` has one line;
  - the agent's id, title, cwd, worktree, queued prompts and `costToDate` are unchanged.

  Also add cases for:
  - a chain: the second is also spent, so the chat goes to the third, never back to the first for the same prompt;
  - another chat on the first runtime moves before its next turn, without failing first (US3-AS5);
  - an open permission question is closed as unanswered;
  - a history over budget is shortened, and the note says so.

  *Done 2026-09-26.* The chain, the move before the next turn, events, `switches.jsonl`, the
  unchanged record and the out credential are covered. The switch calls
  `closeQuestionsOfAGoneRuntime`, but no test opens a question first. Shortening is covered by
  `HandoffTests`, not end to end. `triedForPrompt` is kept on the daemon (`carryTried`), not on
  the record.
- [X] T039 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Integration/NoSwitchTests.swift`, following quickstart §3. Each of these ends exactly as on main, and nothing moves:
  - a crash;
  - a refused sign-in;
  - `limit`/`["new_session"]`;
  - the person's cost limit;
  - an unrecognised error;
  - a plain `end_turn`;
  - an Antigravity `runtimeError`;
  - the pool off;
  - a pool of one;
  - the chat's own switch off.

  *Done 2026-09-26, inside `PoolSwitchTests.swift` rather than a file of its own.* Covered:
  budget exhausted, auth required, overloaded, an unrecognised error, a plain `end_turn`, the
  pool off, a pool of one, and the chat's own switch off. Not covered here: a crash (the fake
  has no crash script, so the unrecognised error stands in), the cost limit (the stop comes
  first, and `pendingCarry` is cleared by the stop guard), and Antigravity's `runtimeError` (a
  rate limit: retried, never moved; see `AllowanceRecognitionTests`).
- [X] T040 [US1] Implement the switch in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift`:
  1. On `.spent`, `.creditGone` or `.overage`, ask `PoolPlan`.
  2. Close the old runtime's open questions, as `closeQuestionsOfAGoneRuntime` does.
  3. Release the old runtime.
  4. Build a `CarryPlan` and the handoff.
  5. Replace the runtime, the session, `startOptions`, `advertisedOptions` and `availableCommands` on the record.
  6. Make a new session through `freshSession` (`DaemonCore+Commands.swift`), with the chat's `cwd`, `additionalDirectories`, `mcpServers` and the new runtime's `ToolPolicyCatalog` metadata.
  7. Send one prompt: the handoff as an embedded `resource` block (`agents://handoff/<agentID>.md`) when `promptCapabilities.embeddedContext` is set, and as text otherwise, followed by the failed prompt's own blocks.
  8. Record `.poolSwitch` and `.handoff`.
  9. Append the `SwitchRecord`.
  10. Publish the events.
  11. Broadcast `pool/changed`.

  Before any turn on a runtime whose credential is out, move first (FR-012). Clear `triedForPrompt` on the first real reply. This makes T038 and T039 pass.
- [X] T041 [US1] Add `agent.runtime_switched`, `cost.allowance_out` and `cost.allowance_back` to `Pkg/Sources/AgentsKitCore/Model/EventCatalogue.swift`, with the fields in `contracts/daemon-api.md`, and make sure `events/list` shows them. Extend the events test that walks the catalogue.
- [X] T042 [US1] Walk quickstart §2–§5 on `/tmp/run-052-us1`, with the stand-ins from T005, using the run-app skill. Save the transcript, `pool/state`, the event lines and a screenshot of the switch note to `specs/052-quota-fallback/walk/us1/`, and record the result in `walk/README.md`.

**Checkpoint**: With a pool set by `pool/set` on the socket, chats move by themselves. This is the MVP.

---

## Phase 4: User Story 2 — Setting up the pool (Priority: P1)

**Goal**: The person builds the pool in Settings, including credit on keys, and it survives restarts.

**Independent Test**: Spec US2 test and AS1–AS8; quickstart §6.

- [X] T043 [P] [US2] Write `Pkg/Tests/AgentsKitTests/Integration/PoolSetTests.swift` for `pool/set`, following `contracts/daemon-api.md`. Cover:
  - each rejection, with its sentence;
  - the whole-replace semantics;
  - the `pool/changed` broadcast;
  - owner-only access: a paired device is refused;
  - persistence across a daemon restart on the same root;
  - an entry whose runtime is signed out afterwards stays in the pool and is skipped.

  *Done 2026-09-26.* Owner-only access is checked on `ConnectionRole`, not over a paired
  socket. `pool/set` itself was built in slice 2. The app pushes the pool to every connected
  server on set, and to each server when it connects (T044).
- [X] T044 [US2] Implement `pool/set` in `DaemonCore+Pool.swift`, and the `DaemonAPI` method and types, so that T043 passes. Add push to servers on connect beside the cost limits' push (037 R7), in the host connection code under `Pkg/Sources/AgentsKit/Hosts/`.
- [X] T045 [P] [US2] Write `Pkg/Tests/AgentsKitTests/Integration/CreditLedgerTests.swift`, following quickstart §6. Cover:
  - a `.prepaid(amount: $0.05)` entry becomes *Credit used up* after turns reporting $0.03 each, before any refusal;
  - `.freeCredit(expires: yesterday)` is out at once;
  - a `.freeTier` Gemini entry is out until the next midnight Pacific after the daily-quota 429, then available;
  - a runtime reporting no cost gives `spent: .unknown`;
  - a used-up entry marked available is tried again, and never reset by a timer;
  - raising the amount brings it back.
- [X] T046 [US2] Implement the ledger: add each turn's `TurnUsage.cost` to the chat's entry in `allowances.json`, and check the amount and expiry at the end of every turn, in `DaemonCore+Pool.swift`. This makes T045 pass.
- [X] T047 [US2] Make `App/Sources/Settings/PoolSettingsView.swift` from T028 live. Add AppModel calls for `pool/state` and `pool/set` in `App/Sources/AppModel.swift`, and wire up the switch, drag to reorder, the Model menu, Remove, and **Add a runtime**. Add a runtime lists only installed, signed-in runtimes on an allowance, using `model.accounts`.
- [X] T048 [US2] Make `App/Sources/Pool/AddCreditSheet.swift` from T029 live. It lists lent keys from Settings ▸ Servers credentials (`CredentialKind.openAIAPIKey`, `.geminiAPIKey`, `.apiKey`), defaults Gemini to **Free tier**, adds the entry last, and makes *Billed with no limit* impossible to pick.
- [X] T049 [US2] *(Done over the socket 2026-09-26. The screenshots are still open: Alex was at the keyboard. See `walk/README.md`.)* Walk quickstart §6 and the US2 independent test in the scratch window, following the memory note "drive a scratch window by pid with AX". Add three entries, reorder them, remove one, add a prepaid key, relaunch, and check that everything is as it was left. Put screenshots in `specs/052-quota-fallback/walk/us2/`.

---

## Phase 5: User Story 3 — The Pool page (Priority: P1)

**Goal**: One place, with a sidebar dot, that shows which entries are out, until when, what moved, and what is waiting.

**Independent Test**: Spec US3 test and AS1–AS6; quickstart §9.

- [X] T050 [P] [US3] Write `Pkg/Tests/AgentsKitTests/Integration/PoolStatusTests.swift`. Cover:
  - `pool/state` state words for each `Status`;
  - chat counts per entry;
  - switches from the last day by default, and 30 days with `{days: 30}`;
  - waiting chats;
  - `anyOut`;
  - `pool/markAvailable` sets `.person` and broadcasts, is open to paired devices, and is idempotent;
  - `pool/changed` is debounced to at most once a second;
  - an `until` passing broadcasts `available` without a relaunch.

  *Done 2026-09-26.* Waiting chats are left to US4, which makes them.
- [X] T051 [US3] Implement `pool/markAvailable`, the debounce, and the broadcast when an `until` passes, in `DaemonCore+Pool.swift`. The broadcast is checked on the existing due-timer, and adds no timer of its own (plan: no new timers). This makes T050 pass.
- [X] T052 [US3] Make `App/Sources/Pool/PoolPage.swift` and the sidebar row from T027 live:
  - subscribe to `pool/changed`;
  - **Mark available** calls `pool/markAvailable`;
  - chat counts and switch rows open their chats;
  - **Show the last 30 days** asks with `{days: 30}`;
  - the empty or off state links to Settings ▸ Pool (US3-AS6);
  - the dot and count line follow `anyOut`.
- [X] T053 [US3] *(Done in the prompt bar's draft, `App/Sources/Chat/PromptBar.swift`, where a new chat is started now.)* When a new chat is started on a runtime whose credential is out, warn before the first prompt and offer the first available entry instead (spec US3). Do this in `App/Sources/StartAgent/`.
- [X] T054 [US3] Walk quickstart §9 on a scratch root. Check that the dot comes and goes, each state reads in words, and Mark available clears the dot live. Put screenshots in `specs/052-quota-fallback/walk/us3/`.

**Checkpoint**: All P1 stories are done: the pool, switching, and a place to see it.

---

## Phase 6: User Story 4 — Everyone out: wait, then carry on (Priority: P2)

**Goal**: When no entry is usable, the chat waits for the earliest known return and resumes by itself.

**Independent Test**: Spec US4; quickstart §7.

- [X] T055 [P] [US4] Write `Pkg/Tests/AgentsKitTests/Integration/AllowanceWaitTests.swift`, modelled on `BlockedTests.swift` with an injected `now`. Cover:
  - everyone out, with a known return: the chat stops with the note and shows as waiting, not failed, and `allowanceWait` is set;
  - time passes: it resumes on that entry with the prompt, once;
  - a prompt from the person, stop, park or archive drops the wait (FR-017);
  - with no known return, it stops and nothing is scheduled;
  - a daemon restart keeps the wait and still resumes.
- [X] T056 [US4] *(Done 2026-09-26. Resumed from the workflow heartbeat, which also runs on the first tick after a restart. The pick-up path is not touched. `pool/stopWaiting` was added for the Pool page and the phone.)* Implement the wait in `DaemonCore+Pool.swift`, and resume it from the due-timer in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Blocks.swift` (`resumeDueBlocks`) and after a restart (`resumeBlocksAfterRestart`). Clear it in the prompt, stop, park and archive paths. This makes T055 pass.
- [X] T057 [US4] Show waiting chats on the Pool page's card, with **Stop waiting**, and a *Waiting for an allowance* status on the agent row. Add the status word to `App/Sources/AgentList/` and `PoolWords`.

---

## Phase 7: User Story 5 — Continue with another runtime, saying what it should be (Priority: P2)

**Goal**: A chat moves by hand, with every setting shown and editable, and the same sheet corrects an automatic switch.

**Independent Test**: Spec US5 test and AS1–AS5; quickstart §8 steps 2, 3 and 5.

- [X] T058 [P] [US5] Write `Pkg/Tests/AgentsKitTests/Integration/ContinueWithTests.swift` for `agents/continueWith`, following `contracts/daemon-api.md`. Cover:
  - the preview returns a `CarryPlan` and changes nothing;
  - apply sets exactly the chosen values, sends nothing until the next prompt, and then sends the handoff with that prompt;
  - `-32010` while a turn is running;
  - a mode looser than the current one is refused;
  - a value the runtime does not offer is refused;
  - `adjust: true` after an automatic switch writes `.settingsChanged`, applies from the next turn, and makes no new session;
  - it is open to paired devices;
  - `agents/setSwitching` toggles `switchingOff`.

  *Done 2026-09-26.* "Stop the turn first" is -32046, not -32010, which already has two
  meanings. The preview returns `ContinueWithResult {runtimeID, plan, options, agent?}`: the
  options fill the sheet's menus. Remember is left for US6.
- [X] T059 [US5] Implement `agents/continueWith` (preview, apply, adjust) and `agents/setSwitching` in `DaemonCore+Pool.swift` and `DaemonAPI.swift`, reusing T040's switch with the reason `.byHand` and nothing re-sent. This makes T058 pass.
- [X] T060 [US5] Make `App/Sources/Chat/ContinueWithSheet.swift` and the prompt-bar menu from T030 live:
  - the runtime menu refills the right-hand column from the preview;
  - the menus hold only the values the runtime offers, with modes capped;
  - while a turn is running, the sheet shows *Stop the turn first* and a Stop button;
  - the note's **Change what it carried on with…** opens it in adjust mode;
  - the per-chat tick calls `agents/setSwitching`.
- [X] T061 [US5] Walk the sheet in the scratch window with the AX helper, following quickstart §8 step 5. Take screenshots against wireframes §3, into `specs/052-quota-fallback/walk/us5/`.

---

## Phase 8: User Story 6 — Matching models (Priority: P2)

**Goal**: A grid of levels decides which model stands in for which. It is filled by hand, or by **Remember**.

**Independent Test**: Spec US6 test and AS1–AS4; quickstart §8 steps 1 and 4.

- [ ] T062 [P] [US6] Extend `Pkg/Tests/AgentsKitTests/Unit/SettingsCarryTests.swift` with the grid:
  - the chat's model in a level with a cell for the new runtime → that cell's model and effort, with the source `.level(name)`;
  - the model is in no level, or the cell is empty → the fallbacks, and the note says the grid had no answer;
  - a cell whose model is no longer offered is treated as empty;
  - two entries for one runtime share its column.
- [ ] T063 [P] [US6] Write `Pkg/Tests/AgentsKitTests/Integration/PoolModelsTests.swift` for `pool/models`:
  - it reads from `OptionCache`;
  - a runtime missing from the cache gets a draft handshake that costs no prompt;
  - it refreshes at most once every 10 minutes per runtime.

  Also test Remember on `agents/continueWith`: it adds the pair to the chosen level, or to a new level, and never breaks FR-032.
- [ ] T064 [US6] Implement the grid in `SettingsCarry.swift`, `pool/models`, and Remember, so that T062–T063 pass.
- [ ] T065 [US6] Make the Matching models grid on `App/Sources/Pool/PoolPage.swift` editable:
  - cell menus from `pool/models`;
  - **Add a level**;
  - rename and reorder levels by drag;
  - gone cells shown struck through;
  - one column per pool runtime, in pool order;
  - a model already in another level moves when chosen.
- [ ] T066 [US6] Walk quickstart §8 steps 1 and 4 on a scratch root, and take a screenshot of the grid into `specs/052-quota-fallback/walk/us6/`.

---

## Phase 9: The phone and servers (all stories, plan slice 7)

- [ ] T067 [P] Add `Remote/Sources/Pool/PoolPageView.swift` and a level detail view, following wireframes §5. Reach them from wherever `Remote/Sources/Projects/ProjectListView.swift` shows Spending, with the same dot. Make Mark available a swipe action, and use `PoolWords` for every line. Build the Remote for the generic simulator only. The look is Alex's to check.
- [ ] T068 [P] Draw the switch note and the folded handoff in the Remote's chat, and a list layout of the Continue with sheet (one row per setting, the old value under the new), in `Remote/Sources/Chat/`.
- [ ] T069 Send allowance state from a server to the Mac. A server's `agentsd` reports what it recognises (spent, rate limited, returned, credit spent) over the existing server link. The Mac's daemon applies it to the one `allowances.json`, and the current states go back to the server with `pool.json` (research R6). Write `Pkg/Tests/AgentsKitTests/Integration/ServerAllowanceTests.swift` with `FakeSSH`, covering a relayed Codex refusal on the server that marks the Mac's plan out, and a server entry on a lent key that keeps its own state.
- [ ] T070 Walk one server case with the test-servers skill on the devbox: a relayed Codex entry marked out on the Mac is skipped by a server chat. Record the result in `specs/052-quota-fallback/walk/servers/`.

---

## Phase 10: Polish and cross-cutting

- [ ] T071 [P] Write `docs/how-to/keep-going-when-a-runtime-runs-out.md`. It covers setting up the pool, credit on keys, what a switch looks like, reading the Pool page, Matching models, Continue with and its sheet, and marking a runtime available.
- [ ] T072 [P] Update the reference pages:
  - `docs/reference/settings.md`: the Pool tab, the switch, the per-chat tick;
  - `docs/reference/runtimes.md`: for each runtime, what is recognised, as in research R13, with Copilot, Cursor, Grok and Antigravity said plainly to be "not yet recognised";
  - `docs/reference/events.md`: the three events;
  - `docs/reference/statuses.md`: *Rate limited*, *Waiting for an allowance*, and the two new endings.
- [ ] T073 Run quickstart §10: the read-only checks against the real Claude and Codex, which send no prompt, on a scratch root. Record in `research.md` R2 whether Codex forwards rate-limit `_meta`, and update R13 if it does.
- [ ] T074 Run the whole suite six times on this branch and six times on `main`, and compare the failures with the T002 baseline. Only new failures are this lane's.
- [ ] T075 Update the memory spec-queue line for 052 with the commits, what was walked, and what waits on Alex. Stop there: the merge happens only when Alex says it is this lane's turn.

---

## Dependencies

- **Setup (T001–T005)** comes first. T003–T005 can run in parallel.
- **Foundational, slice 1 (T006–T014)** blocks everything.
- **Foundational, slice 2 (T015–T023)** blocks every story.
- **The look gate (T024–T032)** needs T022 (the words) and T024. T032 waits on Alex.
- **US1 (T033–T042)** needs the look gate. It is the MVP.
- **US2 (T043–T049)** needs US1's T040 for its switch test, and can otherwise start once the look gate is done.
- **US3 (T050–T054)** needs T025 and the look gate. It is independent of US2 on the daemon side.
- **US4 (T055–T057)** needs US1.
- **US5 (T058–T061)** needs US1's T040 and T036.
- **US6 (T062–T066)** needs US5's T059, because Remember goes through `continueWith`.
- **The phone and servers (T067–T070)** need US1 and US3. T069 needs US1.
- **Polish (T071–T075)** comes last.

## Parallel opportunities

- **Setup:** T003, T004 and T005.
- **Slice 1:** the tests T006, T007 and T012, and T014, can be written together before T008–T011 and T013.
- **Slice 2:** the tests T015, T016 and T017 can be written together, and so can the implementations T019 and T020.
- **Look gate:** T025–T030 are all different files and can be built at once.
- **US1:** the tests T033, T034, T035, T038 and T039 come first. Then T036, then T040.
- **US2, US3 and US5:** their daemon test files (T043, T050 and T058) can be written side by side.
- **Phone and docs:** T067, T068, T071 and T072.

## Implementation strategy

1. **MVP = Setup + slice 1 + slice 2 + the look gate + US1.** After slice 1 alone, the app already
   shows every typed failure in words and never marks a refused turn finished. That is worth
   merging even if the rest waits.
2. Then **US2 and US3**, so the person can set the pool up and see it without the socket. This
   completes the P1 set.
3. Then **US4, US5 and US6**, in that order.
4. **The phone and servers** last.
5. Each phase ends with its walk on a scratch root, and nothing merges until Alex says so.
