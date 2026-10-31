---

description: "Task list for desktop control: an agent drives apps on the Mac, watched from another device"
---

# Tasks: Desktop control: an agent drives apps on the Mac, watched from another device

**Input**: Design documents from `specs/3004-desktop-computer-use/` (spec.md, plan.md, research.md,
data-model.md, contracts/desktop-control-api.md, quickstart.md)

**Prerequisites**: plan.md and spec.md (merged, #3038/#3075); research.md's R1–R11; data-model.md;
contracts/desktop-control-api.md

**Tests**: plan.md's own Testing section asks for them (`Go test ./internal/agentsd/...`, `swift test`
filtered by `scripts/select-test-suites.sh`, a new `Web/test/desktopControl.test.mjs`), so each story
below includes test tasks.

**Organization**: tasks are grouped by the spec's four user stories (US1–US4), in the plan's slice
order (1 → 2 → 3, which is US1+US2 → US3 → US4, since slices 2 and 3 both hold the `chat` area), plus
one cross-cutting phase for FR-010 (Codex's own `computer_use`), which the plan's Slice 4 says "holds
no area either of the others does, and may run at any point alongside them."

**Each slice named in plan.md is its own lane, worktree and pull request (AGENTS.md, #2504, #873)**:
this tasks.md is the full backlog for the feature; a lane picks up the next phase whose prerequisite
phase has landed, not the whole file at once. Slices 2 and 3 are each a UI enhancement (#2811) and wait
for Alex's approval of their screenshots; slice 1's refusal card is small and travels with the tool in
the same slice.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no unmet dependency)
- **[Story]**: which of US1–US4 this task belongs to; Setup, Foundational, the Codex phase and Polish
  carry no story label
- Every description names its exact file path(s)

## Path Conventions

Paths are real repository paths (not a generic placeholder), taken from plan.md's Project Structure and
research.md's file:line references. Areas from `.agents/areas` are noted in brackets where the plan
names them, for the `area:<name>` label each PR gets.

---

## Phase 1: Setup

**Purpose**: stand up the new helper process's shell and settle research R1's one open risk before any
real driving code is written.

- [ ] T001 Create the `Host/AgentsDrive/` executable target, built and packaged the way
      `Host/AgentsWatch` already is (a binary that ends up in Agents Host's `Contents/Helpers`,
      `install_darwin.go:9`'s "Contents/Helpers → Contents/Resources/toolsets" packaging): an empty
      `main.swift` that exits immediately, wired into the Xcode project/build scripts beside
      `agents-watch`. `[machines]`
- [ ] T002 Build a throwaway diagnostic: a `Contents/Helpers/agents-drive` binary that only calls
      `AXIsProcessTrusted()` and prints the answer (quickstart.md "First: confirm the open risk"), ship
      it beside a scratch Agents Host build, trigger the Accessibility prompt, grant it, and read
      System Settings ▸ Privacy & Security ▸ Accessibility to confirm whether the new row says "Agents
      Host" or names the helper by its own path (research R1's open risk). Record the answer at the top
      of `specs/3004-desktop-computer-use/research.md` under R1, since it decides what FR-005's refusal
      card and `docs/how-to/let-an-agent-drive-desktop-apps.md` name (T022, T026, T042). `[machines]`

**Checkpoint**: the helper target exists and builds; R1's naming question has a recorded answer.

---

## Phase 2: Foundational (blocking prerequisites for every user story)

**Purpose**: the wire types, methods and capability every story's tool calls, settings and live tile
depend on. No user story's independent test can run until this phase lands.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

- [ ] T003 [P] Add `DesktopControlSettings{enabled: boolean}`, `DesktopControlRefusal{reason: "off" |
      "accessibilityNotGranted", words: string}`, `DesktopControlState{agentID, app, lastNarration,
      paused: boolean, pausedAt: WireDate?}` and `LiveFrame` (one of `{agentID, image: string,
      capturedAt: WireDate}` or `{agentID, locked: true, capturedAt: WireDate}`, `image` never present
      in the locked case) to `Packages/Wire/daemon.schema.json` (data-model.md). `[build]`
- [ ] T004 [P] Add the `drive_screen` tool and its `DriveScreenCall` params (`app: string`, `action:
      "screenshot" | "click" | "type" | "key" | "read"`, `label: string?`, `x: number?`, `y: number?`,
      `text: string?`, `keyName: string?`) to `Packages/Wire/app-tools.json`, mirrored in
      `Go/wire/app-tools.json` (data-model.md, contracts/desktop-control-api.md). `[build]`
- [ ] T005 [P] Add `desktopControl/state`, `desktopControl/set`, `desktopControl/resume`,
      `desktopControl/takeOver` methods and `desktopControl/stateChanged`, `desktopControl/liveFrame`
      notifications to `Packages/Wire/daemon.openrpc.json`, each with `x-capability:
      host.desktop-control/1` (contracts/desktop-control-api.md, research R8). `[build]`
- [ ] T006 Run `scripts/wire.sh gen` under the "build" lease and commit what it makes
      (`Go/wire/*_gen.go`, `Web/src/protocol/generated.ts`). Depends on T003–T005. `[build]`
- [ ] T007 Write the Swift mirrors `WireSchemaTests` flags for the new types in
      `Packages/AgentsKit/Sources/AgentsKitCore/Model/DesktopControl.swift` (decode, words; data-model.md).
      Depends on T006. `[agent-tools]`
- [ ] T008 Declare `host.desktop-control/1` in `Go/internal/agentsd/capabilities.go`'s `host/hello`
      capability list (research R8). Depends on T006. `[machines]`

**Checkpoint**: the new wire types, methods and capability exist end to end (Go, Swift, TypeScript); no
user story's own handler exists yet.

---

## Phase 3: User Story 1 - An agent gets through an app with no API, and the person can stop it (P1) 🎯 MVP

**Goal**: `drive_screen` takes the `screen` lease, drives a named app through the Accessibility API and
synthetic mouse/keyboard events, records each step as an ordinary turn step, and **Stop** halts it and
frees the lease.

**Independent Test**: on a scratch set-up with Accessibility granted, give an agent a task reachable
only by clicking a non-browser app. Confirm it completes using `drive_screen`, the chat shows each step,
a second agent calling the tool queues behind the first, and pressing Stop at any point halts it and
frees the `screen` lease (spec Acceptance Scenarios 1, 2, 4).

### Tests for User Story 1

- [ ] T009 [P] [US1] Go test: lease take on first call, release on Stop, and a second agent queuing on
      `"screen"` (mirroring `lease_resource`'s own queuing test) in
      `Go/internal/agentsd/screencalls_test.go`.

### Implementation for User Story 1

- [ ] T010 [P] [US1] `agents-drive`: AX-addressed actions — find-by-label + `kAXPressAction` for
      `click` with a `label`, `AXUIElementCreateApplication(pid)` tree dump for `read` (mirroring
      `.agents/skills/run-app/scripts/ui.swift`'s `find`/`press`/`dump`) — in
      `Host/AgentsDrive/AXDriver.swift`. `[machines]`
- [ ] T011 [P] [US1] `agents-drive`: real mouse and keyboard synthesis — `CGEventCreateMouseEvent`/
      `CGEventCreateKeyboardEvent` posted with `CGEventPost(.cghidEventTap, …)` for `click` by `x,y`,
      `type` and `key`, each event tagged with `CGEventSetIntegerValueField(event,
      .eventSourceUserData, agentsDriveMarker)` before posting (research R2) — in
      `Host/AgentsDrive/InputSynthesis.swift`. `[machines]`
- [ ] T012 [P] [US1] `agents-drive`: the `screenshot` action — `CGWindowListCreateImage(CGRect.infinite,
      .optionOnScreenOnly, kCGNullWindowID, [])` on the main display, downscaled to stay well under an
      ordinary chat image's size (research R3) — in `Host/AgentsDrive/Screenshot.swift`. `[machines]`
- [ ] T013 [US1] `agents-drive`: the NUL-delimited stdin/stdout protocol — commands in (`screenshot`,
      `click <app> <label-or-x,y>`, `type <text>`, `key <name>`, `read <app>`), replies out (`ok`, a
      screenshot handed back once and not kept) — in `Host/AgentsDrive/main.swift`. Depends on
      T010–T012. `[machines]`
- [ ] T014 [US1] Go: `driveHelper()`, a sibling-path finder for `agents-drive` mirroring
      `watchHelper()` (`Go/internal/agentsd/machine_darwin.go:14-16`) — in
      `Go/internal/agentsd/screencalls.go`. `[machines]`
- [ ] T015 [US1] Go: the `drive_screen` handler — resolves and leases `"screen"` by reusing
      `resolveResource`/`leaseResource`'s internal grant/queue path (`Go/internal/agentsd/leasecalls.go`,
      research R4), starts and talks to `agents-drive` over the protocol from T013, returns its result
      — in `Go/internal/agentsd/screencalls.go`. Depends on T013, T014. `[machines]`
- [ ] T016 [US1] Go: `appToolCalls()` in `Go/internal/agentsd/leasewaits.go` gains `drive_screen`;
      `offeredTools()` gates it on `host.desktop-control/1` (`leasewaits.go:356-380`). Depends on T008,
      T015. `[agent-tools]`
- [ ] T017 [US1] Go: Stop releases the `"screen"` lease and tells `agents-drive` to stop its current
      action, the same shape every other cancelled tool call already gets — in
      `Go/internal/agentsd/turns.go` and `Go/internal/agentsd/lean.go`. Depends on T015. `[machines]`
- [ ] T018 [US1] docs: add the `drive_screen` row to `docs/reference/agent-tools.md` (in the same table
      as `show_file`/`ask_question`, naming the `screen` lease it takes); add the "now actually
      acquired by a shipped tool" line to `docs/explanation/leases.md`. `[docs]`

**Checkpoint**: an agent can drive a non-browser app end to end and Stop frees the lease; US1 is
independently testable and demoable (desktop control gated only by Accessibility being granted, not yet
by the Off switch — US2 adds that gate).

---

## Phase 4: User Story 2 - Turning it on, and the one-time Accessibility grant (P1)

**Goal**: desktop control defaults Off with a refusal naming the rule; turning it on and granting
Accessibility is a one-time step; `drive_screen` refuses until both are true.

**Independent Test**: on a fresh scratch install, confirm the switch defaults to Off with an explanatory
line. Turn it on, trigger a `drive_screen` call, confirm macOS's Accessibility prompt appears for the
process from T002's finding; until approved, confirm the call fails with a card naming where to grant
it; after approval, confirm a second call succeeds with no further prompt (spec US2 Acceptance Scenarios
1–3).

### Tests for User Story 2

- [ ] T019 [P] [US2] Go test: the `"off"` refusal and the `"accessibilityNotGranted"` refusal paths of
      `drive_screen`, and that `desktopControl/set` is refused `forbidden` from the agent socket role, an
      MCP tool, and a workflow, in `Go/internal/agentsd/screensettings_test.go`.

### Implementation for User Story 2

- [ ] T020 [P] [US2] Go: `desktop-control.json` `{enabled: bool}` read/write via `d.writeSetting`
      (the `sandbox.json`/`display.json` pattern, `sandbox.go:244`), and the `desktopControl/state` and
      `desktopControl/set` handlers (`set` refused `forbidden` from the agent socket role, an MCP tool, or
      a workflow — research R5) — in `Go/internal/agentsd/screensettings.go`. `[machines]`
- [ ] T021 [US2] Go: `drive_screen`'s handler (T015) gains the Off/not-granted gate at its entry,
      returning `DesktopControlRefusal{reason: "off" | "accessibilityNotGranted", words}` before taking
      the lease — in `Go/internal/agentsd/screencalls.go`. Names the process T002 found (Agents Host, or
      `agents-drive` by its own path) in `words`. Depends on T015, T020. `[machines]`
- [ ] T022 [P] [US2] `Shared/UI/Chat/DesktopControlRefusalCard.swift` (new): the Off / Accessibility-
      not-granted card, naming the rule and where to turn it on or grant Accessibility — drawn by the Mac
      window and the Remote. `[chat]`
- [ ] T023 [P] [US2] Web twin of the refusal card in `Web/src/views/chat/` (new file alongside the other
      chat-card components). `[chat]`
- [ ] T024 [P] [US2] `App/Sources/Settings/`: the desktop-control switch, off by default, with a line
      explaining what it allows and that macOS will ask for Accessibility on first use; calls
      `desktopControl/set`. `[settings]`
- [ ] T025 [P] [US2] Web twin of the Settings switch in `Web/src/views/settings/`, calling
      `desktopControl/set`. `[settings]`
- [ ] T026 [US2] docs: add the desktop-control switch to `docs/reference/settings.md` (off by default;
      what turning it on asks of macOS; names the process T002 found). `[docs]`

**Checkpoint**: desktop control is off by default everywhere, turning it on and granting Accessibility
is the only way to clear `drive_screen`'s gate, and both refusal states show a card naming what to do.

**Parity**: the Settings switch is Mac + web (on neither the Core nor the Mac+web list by name, so it
takes AGENTS.md's default); its own commit's `remote:` line is `tier mac+web`.

---

## Phase 5: User Story 3 - The person's own touch pauses the agent, never fights it (P2)

**Goal**: the moment the person touches the real mouse or keyboard while the lease is held, the current
action stops, and every client offers Resume/Take Over.

**Independent Test**: on a scratch set-up, start a `drive_screen` run, then move the real mouse or press
a key. Confirm the action stops within the second (over 20 tries) and a card offers Resume/Take Over on
every client; confirm each choice does what it says (spec US3 Acceptance Scenarios 1–3, SC-002).

### Tests for User Story 3

- [ ] T027 [P] [US3] Go test: the pause/resume/takeOver state transitions (data-model.md's "Pause on
      touch" diagram), including `notPaused`/`notHeld` refusals, in
      `Go/internal/agentsd/screenpause_test.go`.

### Implementation for User Story 3

- [ ] T028 [US3] `agents-drive`: a global, listen-only `CGEventTap` (tap point `.cghidEventTap`) that
      filters out any event carrying the `agentsDriveMarker` from T011 and reports every other real
      mouse/key event to `agentsd` over the protocol as `touch` the instant it arrives (research R2) —
      in `Host/AgentsDrive/TouchFilter.swift`. Depends on T011. `[machines]`
- [ ] T029 [US3] Go: `DesktopControlState` kept per agent holding the `screen` lease; `desktopControl/
      resume` (refused `notPaused` when not paused) and `desktopControl/takeOver` (refused `notHeld` when
      the agent does not hold the lease; releases it at once through R4's internal path) handlers;
      raises `desktopControl.paused`/`desktopControl.resumed`/`desktopControl.takenOver` events and
      pushes `desktopControl/stateChanged` on every change — in `Go/internal/agentsd/screenpause.go`.
      Depends on T015. `[machines]`
- [ ] T030 [US3] Go: wire the `touch` word from `agents-drive` (T028) into T029's pause transition — in
      `Go/internal/agentsd/screencalls.go` and `Go/internal/agentsd/screenpause.go`. Depends on T028,
      T029. `[machines]`
- [ ] T031 [P] [US3] `Shared/UI/Chat/DesktopControlPauseCard.swift` (new): Resume and Take Over —
      drawn by both the Mac window and the Remote. `[chat]`
- [ ] T032 [P] [US3] `Web/src/views/chat/DesktopControlPauseCard.tsx` (new): the web twin. `[chat]`

**Checkpoint**: a real touch always pauses the run within a second, and Resume/Take Over both work from
every client.

**Parity**: Core (all three clients); this phase's own commit needs no follow-up `remote:`/`web:` line
since all three ship together.

---

## Phase 6: User Story 4 - Watching live from the Remote or the web page (P2)

**Goal**: every paired client shows a live tile (latest screenshot or "Mac is locked" + narration) for a
session holding the `screen` lease, refreshed within bounds, with no screenshot ever saved.

**Independent Test**: on the walk simulator (or a paired iPhone) and on the web page, open a session that
holds the `screen` lease. Confirm the live tile appears with no setup step, refreshes on its own, shows
the locked placeholder with no pixels while the screen is locked, and that a notice arrives when the run
pauses or ends while backgrounded (spec US4 Acceptance Scenarios 1–4, SC-001, SC-005).

### Tests for User Story 4

- [ ] T033 [P] [US4] Vitest: the tile and the pause card, including the locked-placeholder path, in
      `Web/test/desktopControl.test.mjs`.

### Implementation for User Story 4

- [ ] T034 [US4] Go: push `desktopControl/liveFrame` (the `LiveFrame` type from T003) only to clients
      currently showing the session (`d.showers`, the same gate `tellEntry` already uses), never to
      `d.record`; send `{agentID, locked: true, capturedAt}` with no `image` field while
      `d.personAway() == "locked"` (FR-012) — in `Go/internal/agentsd/turns.go` and
      `Go/internal/agentsd/lean.go`. Depends on T015. `[machines]`
- [ ] T035 [P] [US4] `Shared/UI/Chat/DesktopControlTile.swift` (new): the live tile — latest screenshot
      or "Mac is locked" placeholder, plus the current narration line, refreshed within 2 s of each
      action and at least every 5 s idle — drawn by the Mac window and the Remote. `[chat]`
- [ ] T036 [P] [US4] `Web/src/model/desktopControl.ts` (new) and `Web/src/views/chat/
      DesktopControlTile.tsx` (new): the web twin of the tile. `[chat]`
- [ ] T037 [US4] `Web/src/views/chat/Rows.tsx`: draw the tile beside the existing `LiveLine`. Depends on
      T036. `[chat]`
- [ ] T038 [US4] parity: add the live-tile row, Tier **Core**, to `specs/071-web-remote/walks/
      parity.md` and `specs/071-web-remote/walks/parity/chat-turns-and-turn-detail.md`. `[docs]`
- [ ] T039 [US4] docs: `docs/how-to/let-an-agent-drive-desktop-apps.md` (new) — turning desktop control
      on, granting Accessibility (naming the process T002 found), what the agent can and cannot do, and
      the Resume/Take Over/Stop controls; update `docs/reference/feature-matrix.md`'s browser-row
      neighbour with the desktop-control line. `[docs]`

**Checkpoint**: all three clients show the live tile for a session holding `screen`, the locked
placeholder never carries pixels, and no screenshot is ever written to disk or saved history (SC-005).

**Parity**: Core (all three clients); no follow-up `remote:`/`web:` line needed, same as Phase 5.

---

## Phase 7: Codex's own `computer_use` is turned off (FR-010)

**Goal**: a runtime's own built-in computer-use feature is never passed through or run alongside this
tool. No spec user story names this directly (it is Decisions/FR-010), and it shares no area with
Phases 3–6, so per plan.md's Slice 4 it "may run at any point alongside them."

- [ ] T040 [P] Go: `toolPolicyEnv["codex"]["CODEX_CONFIG"]["features"]` gains `"computer_use": false`
      beside the existing `sleep_tool`/`apps` entries, applied by `withToolPolicy` on every launch — in
      `Go/internal/agentsd/runtimes.go` (research R10). `[runtimes]`
- [ ] T041 [P] Go test: a scratch Codex launch's effective `features` map includes `computer_use: false`
      in `Go/internal/agentsd/runtimes_test.go`.
- [ ] T042 docs: split `docs/reference/runtimes.md`'s `computer_use` row (`:334`) into its own row,
      "Superseded by the app's own desktop-control tool," naming this feature; `browser_use` and
      `image_generation` keep today's "Measure" row. `[docs]`

**Checkpoint**: no runtime's own computer-use feature runs alongside `drive_screen` in the same session.

---

## Final Phase: Polish & Cross-Cutting Concerns

**Purpose**: the checks every phase above still owes before its own PR lands, plus the full walk once
every phase has shipped.

- [ ] T043 [P] Run `scripts/go-changed.sh` under the "build" lease before any push that changes `Go/`
      (any phase touching `Go/internal/agentsd/`).
- [ ] T044 [P] Run `swift test` (filtered by `scripts/select-test-suites.sh`) and `WireSchemaTests` under
      the "build" lease (any phase touching `Packages/AgentsKit` or `Shared/UI`).
- [ ] T045 Full `quickstart.md` validation pass across all four slices, once every phase above has
      merged: the open risk's recorded answer (T002) still matches, SC-001 through SC-005 all hold, and
      the screenshots for Phases 5 and 6's UI-enhancement approvals are attached to their PRs (#2811).

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies; T002's finding feeds T021/T026/T039's wording later.
- **Foundational (Phase 2)**: depends on Setup; BLOCKS every user story (T003–T008 are the wire types
  and capability every later handler, card and tile import).
- **User Story 1 (Phase 3)**: depends on Foundational. The MVP — no dependency on US2–US4.
- **User Story 2 (Phase 4)**: depends on Foundational and on T015 (US1's `drive_screen` handler), whose
  entry point T021 extends with the Off/not-granted gate. Independently testable once T015 exists, even
  before the rest of US1's AX/input work (T010–T012) is real.
- **User Story 3 (Phase 5)**: depends on Foundational and on T011 (the event tagging) and T015.
- **User Story 4 (Phase 6)**: depends on Foundational and on T015; independent of US3 (a tile can show
  an un-paused run), though both ship together per plan.md since they share the `chat` area.
- **Codex `computer_use` off (Phase 7)**: depends only on Foundational's wire work being unnecessary for
  it (it touches no wire type) — may run at any point alongside Phases 3–6 (plan.md's Slice 4).
- **Polish (Final Phase)**: depends on every phase whose checks it runs; T045 depends on all of Phases
  3–7.

### Plan's slice → lane mapping (one PR per slice, AGENTS.md #2504, #873)

- **Lane A** (`machines`, `agent-tools`, `settings` areas): Phases 1–4 (Setup, Foundational, US1, US2) —
  plan.md's Slice 1.
- **Lane B** (`machines`, `chat` areas): Phase 5 (US3) — plan.md's Slice 2. Starts only once Lane A's PR
  has auto-merge on.
- **Lane C** (`machines`, `chat` areas): Phase 6 (US4) — plan.md's Slice 3. Starts only once Lane B's PR
  has auto-merge on (both hold `chat`).
- **Lane D** (`runtimes`, `docs` areas): Phase 7 — plan.md's Slice 4. Holds no area Lanes A–C hold; may
  run at any point alongside them.

### Within each user story

- Tests are written alongside (not strictly before) implementation here, since this is systems code
  (AX, `CGEvent`, a sibling process) rather than a pure API; `agents-drive`'s pieces (T010–T012) can be
  built and unit-tested in parallel, then wired together (T013).
- The Go handler (lease take/dispatch) comes before the UI that reacts to its refusals or state.
- Within Phase 3: T010–T012 (agents-drive internals) before T013 (the protocol that ties them together)
  before T014–T015 (Go's side of that protocol) before T016–T017 (wiring into the tool-call and stop
  paths).

### Parallel opportunities

- T003, T004, T005 (independent sections of the wire schema) in parallel.
- Within Phase 3: T010, T011, T012 in parallel (different files, each self-contained before T013 ties
  them together).
- Within Phase 4: T022, T023, T024, T025 in parallel (four independent UI files).
- Within Phase 5: T031, T032 in parallel. Within Phase 6: T035, T036 in parallel.
- Phase 7 (T040–T042) in parallel with Phases 3–6 once Phase 2 lands, per plan.md.

---

## Parallel Example: User Story 1

```bash
# Launch agents-drive's three independent pieces together:
Task: "AX-addressed actions in Host/AgentsDrive/AXDriver.swift"
Task: "Real mouse/keyboard synthesis in Host/AgentsDrive/InputSynthesis.swift"
Task: "Screenshot capture in Host/AgentsDrive/Screenshot.swift"
# Then, once all three exist:
Task: "The stdin/stdout protocol in Host/AgentsDrive/main.swift"
```

---

## Implementation Strategy

### MVP first (User Story 1 only)

1. Complete Phase 1: Setup (confirm R1's open risk early — it decides wording two stories need later).
2. Complete Phase 2: Foundational (wire types, capability) — blocks everything else.
3. Complete Phase 3: User Story 1 — an agent can drive a non-browser app and Stop frees the lease.
4. **STOP and VALIDATE**: quickstart.md Slice 1, steps 4–6, on a scratch root.
5. This is demoable on its own, gated only by Accessibility (not yet by an Off switch — see below).

### Incremental delivery

1. Setup + Foundational → foundation ready.
2. Add User Story 1 → independently testable (gated by Accessibility only).
3. Add User Story 2 → the Off-by-default switch now actually gates US1's tool; independently testable
   on a fresh install.
4. Add User Story 3 → pause-on-touch, Resume, Take Over; independently testable with a real mouse.
5. Add User Story 4 → the live tile on all three clients; independently testable on the walk simulator
   and headless Chrome.
6. Phase 7 (Codex's own `computer_use` off) lands whenever its lane has a free place — no ordering
   constraint against 3–6.
7. Final Phase once all of the above have merged.

### One lane at a time per area (#873)

Because Phases 3–4 and Phases 5–6 share the `machines`/`chat` areas with each other, AGENTS.md's "one
lane per feature area at a time" means Lane B (Phase 5) does not start until Lane A's PR has auto-merge
on, and Lane C (Phase 6) does not start until Lane B's PR has auto-merge on. Lane D (Phase 7) has no such
wait.

---

## Notes

- [P] tasks touch different files with no unmet dependency.
- [US1]/[US2]/[US3]/[US4] map each task to the spec's own user stories for traceability.
- Every file path above is taken from plan.md's Project Structure or research.md's `file:line`
  references, not invented fresh.
- Phases 4 (US2) and 6 (US4) are UI enhancements and wait for Alex's screenshot approval (#2811) before
  their PR's auto-merge goes on; Phase 5 (US3) likewise, since its pause card is new chat UI. Phase 3
  (US1)'s refusal card is a small part of the same tool and travels with it in the same PR rather than
  waiting on its own (plan.md's own slice note).
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
