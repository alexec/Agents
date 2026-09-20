---

description: "Tasks for 018 visual-consistency"
---

# Tasks: Visual Consistency — One Attention Colour, One Chat Scale, One Measure

**Input**: Design documents from `/specs/018-visual-consistency/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/ui.md](contracts/ui.md), [quickstart.md](quickstart.md)

**Tests**: Included, because this feature requires them. FR-024, FR-025 and FR-026 each say
"a check MUST fail when…", and User Story 4 is nothing but those checks. `ChatMetrics` is
arithmetic in the package and is tested the way `PageMetrics` is.

**Organization**: By user story. US1, US2 and US3 are independent of each other and can be
done in any order once Phase 2 is green.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files, no dependency on an unfinished task
- **[Story]**: US1 colour, US2 type scale, US3 measure, US4 the checks

## Path Conventions

Two app targets and one package, per [plan.md](plan.md#project-structure):

- `Shared/UI/` — new, compiled into both apps
- `Packages/AgentsKit/Sources/AgentsKitCore/` — arithmetic, no SwiftUI
- `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` — the only test target
- `App/Sources/`, `Remote/Sources/` — the two apps

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Somewhere for shared UI code to live. The two apps share no view code today,
which is how they drifted; this is the precondition for every other phase.

- [X] T001 Create the directory `Shared/UI/` with a `README.md` stating what belongs there: SwiftUI code compiled into both the `Agents` and `Remote` targets, and why arithmetic goes to `AgentsKitCore` instead (adding `import SwiftUI` to the package would make `agentsd` link SwiftUI, because the daemon reaches Core through `AgentsKit`)
- [X] T002 Add `- path: Shared/UI` under `sources:` for both the `Agents` and `Remote` targets in `project.yml`, with a comment naming the drift it exists to prevent
- [X] T003 Run `xcodegen generate` from the repo root and confirm both targets build: `xcodebuild -scheme Agents build` and `xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' build`

**Checkpoint**: `Shared/UI` exists, is compiled into both apps, and nothing has changed visually.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one type every story's call sites will reference. Nothing uses it yet.

**⚠️ CRITICAL**: T004–T006 block US1. US2 and US3 do not depend on them and may start in parallel.

- [X] T004 Create `Shared/UI/StateTint.swift` with `enum StateTint { case attention, failure, vouched, none }` and `var color: Color?` returning orange, red, green and `nil` respectively, per [data-model.md](data-model.md#statetint). Document in the doc comment that `attention` is deliberately not `Color.accentColor` (FR-005) and that `none` returns `nil` so a call site keeps its existing `.secondary`/`.tertiary` rather than being flattened (FR-006)
- [X] T005 Add `static func of(_ agent: Agent) -> StateTint` to `Shared/UI/StateTint.swift`, returning `.attention` when `agent.needsAPerson`, `.vouched` when `agent.state == .finished && agent.report?.outcome == .done`, and `.none` otherwise. Read `Agent.needsAPerson` from `AgentGroup.swift:100` — do not redefine it (FR-001)
- [X] T006 Add a doc comment to `Shared/UI/StateTint.swift` recording that green survives because feature 014 gave it deliberately to a self-reported `done` (its FR-012), and that this is why the palette is three colours rather than two

**Checkpoint**: `StateTint` compiles into both apps. No call site uses it. Nothing has changed visually.

---

## Phase 3: User Story 1 - One colour means one thing (Priority: P1) 🎯 MVP

**Goal**: One colour for "a person is needed", across both apps and every surface.

**Independent Test**: Put one project into a state with a waiting agent, an agent that reported `done`, a stalled workflow, a missing folder and an agent at its cost limit. Every surface that draws them — Mac agent list, project row dot, project page, workflow row, chat; phone project list, agent card, chat — shows attention as one hue, failure as another, `done` as green, everything else grey.

### Attention sites — must end up orange

- [X] T007 [P] [US1] In `App/Sources/AgentList/AgentRow.swift`, replace the `tint` computed property's literals (lines ~174-181) with `StateTint` cases: `.attention` for `settledOutcome.needsAPerson` and `.waitingOnUser`, `.vouched` for `.done`, `.none` otherwise. Keep the existing `settledOutcome` logic and every comment
- [X] T008 [P] [US1] In `App/Sources/Chat/Transcript.swift:364`, replace `AnyShapeStyle(.orange)` with the `StateTint.attention` colour, keeping the `.secondary` fallback
- [X] T009 [P] [US1] In `App/Sources/Projects/WorkflowRow.swift:103`, replace `AnyShapeStyle(Color.red)` with `StateTint.attention` — this is a colour change, red to orange. Update the comment above it, which currently says "The app's one use of colour", to name the shared definition instead
- [X] T010 [P] [US1] In `App/Sources/Projects/WorkflowRow.swift:215`, replace `AnyShapeStyle(Color.red)` with `StateTint.attention` — red to orange
- [X] T011 [P] [US1] In `App/Sources/Projects/ProjectRow.swift:33`, replace `.fill(Color.accentColor)` on the `needsPerson` dot with `StateTint.attention` — accent to orange (FR-005)
- [X] T012 [P] [US1] In `Remote/Sources/Projects/AgentCard.swift:175-178`, replace the `tint` property's `.accentColor` with `StateTint` cases matching `AgentRow`'s, so the two cannot diverge — accent to orange
- [X] T013 [P] [US1] In `Remote/Sources/Projects/ProjectListView.swift:56`, replace `.fill(Color.accentColor)` on the `summary.needsInput` dot with `StateTint.attention` — accent to orange
- [X] T014 [P] [US1] In `Remote/Sources/Chat/EntryView.swift:143`, replace `AnyShapeStyle(Color.accentColor)` with `StateTint.attention` — accent to orange

### Failure sites — red, via the shared definition

- [X] T015 [P] [US1] In `App/Sources/Projects/ProjectAgentsView.swift:68` and `Remote/Sources/Projects/ProjectPageView.swift:125`, replace `Color.red` on the missing-folder label with `StateTint.failure`. No visible change
- [X] T016 [P] [US1] In `App/Sources/Chat/Transcript.swift:611` and `Remote/Sources/Chat/EntryView.swift:276`, replace `AnyShapeStyle(.red)` on the failed-call style with `StateTint.failure`. No visible change
- [X] T017 [P] [US1] In `App/Sources/Settings/CostSettingsView.swift:82`, `App/Sources/Projects/ProjectListView.swift:201` and `Remote/Sources/Projects/TotalsView.swift:91`, replace `AnyShapeStyle(.red)` on the spend styles with `StateTint.failure`. No visible change
- [X] T018 [P] [US1] In `App/Sources/Chat/ContextMeter.swift:30,73` and `Remote/Sources/Chat/RemoteChatView.swift:236,246`, replace `AnyShapeStyle(.red)` on the context-full styles with `StateTint.failure`. No visible change
- [X] T019 [P] [US1] In `App/Sources/Chat/PlanView.swift:74,77`, `App/Sources/Chat/AttachmentStrip.swift:22`, `App/Sources/Elicitation/ElicitationView.swift:221` and `App/Sources/Runtimes/RuntimeAccountView.swift:25`, replace `.red` with `StateTint.failure`. No visible change

### Orange spent on something else — moving to red (FR-006a)

- [X] T020 [P] [US1] In `App/Sources/Sidebar/ArtifactsPane.swift:57`, change the "no longer there" label from `.orange` to `StateTint.failure` — a missing artifact is the same news as a missing folder
- [X] T021 [P] [US1] In `App/Sources/Settings/CostSettingsView.swift:175`, change the warning label from `.orange` to `StateTint.failure`
- [X] T022 [P] [US1] In `App/Sources/Chat/PromptBar.swift:153`, change the at-cost-limit triangle from `.orange` to `StateTint.failure`. Record in a comment that an agent at its limit is treated as blocked rather than as asking a question, per the spec's Assumptions

### Verify

- [X] T023 [US1] Confirm `Remote/Sources/Chat/EntryView.swift:329` is untouched — it is an accent-coloured button that opens a diff, a control and not a state, and is explicitly out of scope (FR-006b)
- [ ] T024 [US1] Walk [quickstart.md §4](quickstart.md#4-colour-by-eye) on both apps: all five states, both appearances, system accent set to orange, and each state readable from its icon and words alone (FR-007, FR-008)

**Checkpoint**: One colour per meaning, everywhere. SC-001 met. US1 is independently shippable.

---

## Phase 4: User Story 2 - Chat reads at one size (Priority: P1)

**Goal**: The transcript on one type scale, and the two apps agreeing entry-for-entry.

**Independent Test**: Open a transcript containing every entry kind on both apps. Nothing is two steps smaller than the thing above it without reason, and each kind sits at the same relative step on both.

**Scope note**: The scale covers *transcript entry renderers*. The prompt bar, the document and file readers, and the capsule/badge chrome are not entries and keep their own sizes; their decorative glyph sizes are exempt from FR-015 and must be marked as such.

- [X] T025 [US2] Create `Shared/UI/ChatTypeScale.swift` with `enum ChatTypeStep { case prose, supporting, fine, code }` and `extension View { func chatText(_ step: ChatTypeStep) -> some View }`, resolving to `.body`, `.callout`, `.caption` and `.callout.monospaced()` per [data-model.md](data-model.md#chattypescale). Document that `supporting` is exactly one step below `prose` (FR-011) and `fine` at most two (FR-012), and that no step may be a fixed point size (FR-015)
- [X] T026 [P] [US2] In `App/Sources/Chat/BlocksView.swift`, move the undrawable-image, audio and resource-link placeholders (lines 36, 42, 50) from `.footnote` to `.chatText(.supporting)`, and the resource label and unknown-block text (lines 57, 66) to `.chatText(.fine)`
- [X] T027 [P] [US2] In `Remote/Sources/Chat/BlocksView.swift`, move the resource-link, audio and unknown-block renderers (lines 33, 46, 51) onto the same steps T026 uses, so the two files name the same step for the same block kind (FR-014)
- [X] T028 [P] [US2] In `App/Sources/Chat/Transcript.swift`, move all 25 `.font(...)` call sites onto `chatText(_:)` steps: agent and person messages to `prose`, thoughts and tool titles and the "Agents asked" body to `supporting`, timestamps and metadata to `fine`, monospaced content to `code`. Remove the explicit `.font(.callout)` at lines 264, 280 and 548 — `supporting` now supplies it
- [X] T029 [P] [US2] In `Remote/Sources/Chat/EntryView.swift`, move all 25 `.font(...)` call sites onto the same steps T028 uses for the same entry kinds (FR-013)
- [X] T030 [P] [US2] In `App/Sources/Chat/MarkdownText.swift` and `Remote/Sources/Chat/MarkdownText.swift`, move body text, code blocks (`.footnote.monospaced()`), table cells and language tags onto steps. Leave heading sizes (`.title3` / `.headline` / `.subheadline`) as they are — they already agree across both apps and are not a step
- [X] T031 [P] [US2] In `App/Sources/Chat/PlanView.swift` and `Remote/Sources/Chat/PlanView.swift`, move all `.font(...)` call sites onto steps, keeping the two files in step with each other
- [X] T032 [P] [US2] In `App/Sources/Chat/DiffView.swift`, move the four `.font(...)` call sites onto steps — diff bodies to `code`, the header to `fine`
- [X] T033 [P] [US2] In `App/Sources/Chat/CommandList.swift`, move the three `.font(...)` call sites onto steps
- [X] T034 [P] [US2] In `App/Sources/Chat/AttachmentStrip.swift`, move the text `.font(...)` sites onto steps. The `.system(size: 10)` at line 16 and `.system(size: 8, weight: .bold)` at line 29 are glyphs inside a badge — keep them and add a comment marking them decorative and exempt from FR-015
- [X] T035 [US2] Confirm no transcript *text* anywhere in `App/Sources/Chat/` or `Remote/Sources/Chat/` still uses `.system(size:)`. The remaining instances — `SelectCapsule.swift:22,64`, `JumpToEnd.swift:18`, `PromptBar.swift:691`, `Remote/.../PromptBar.swift:60`, `RemoteChatView.swift:322` — are capsule and badge glyphs, not entries; add a one-line comment to each marking it decorative
- [ ] T036 [US2] Walk [quickstart.md §5](quickstart.md#5-size-and-measure-by-eye) for size only: open a transcript with every entry kind on both apps and compare kind by kind, paying particular attention to the `BlocksView` placeholders that disagreed before
- [ ] T037 [US2] Raise system text size to its largest setting and confirm every part of the transcript scales and no row clips (FR-015, SC-008)

**Checkpoint**: The transcript reads at one scale on both apps. SC-003 and SC-004 met.

---

## Phase 5: User Story 3 - The chat fits the space it is given (Priority: P1)

**Goal**: The chat's fixed 288pt of gutter becomes a centred ceiling that gives way before the text does.

**Independent Test**: Drag the window from narrowest to widest with the right sidebar open and shut. The column never collapses, never exceeds the cap, and the prompt bar's edges track the transcript's at every width.

**⚠️ Do this phase last of the three visible ones.** `Transcript.swift:59-90` does delicate work around `bottomInset`, the floating prompt bar and a `ScrollViewReader`; changing column width mid-scroll will fight with it (see [plan.md Risks](plan.md#risks)).

### The arithmetic

- [X] T038 [US3] Measure the real chat pane width in the running app at the default 1100pt window with the right sidebar open and with it shut, and record both numbers. Do not guess the cap — `PageMetrics` got its 500 from a measurement and says so in its doc comment
- [X] T039 [US3] Create `Packages/AgentsKit/Sources/AgentsKitCore/UI/ChatMetrics.swift` with `measure`, `padding`, `measureCap`, `widePadding`, `tightPadding` and `static func forPane(width:) -> ChatMetrics`, modelled on `Packages/AgentsKit/Sources/AgentsKit/Files/PageMetrics.swift`. Ramp the padding between the tight and wide widths rather than stepping — `PageMetrics`'s comment explains why: a step makes the measure jump *outwards* as the pane narrows, which reads as a glitch while somebody is dragging the resize handle. No `import SwiftUI` in this file
- [X] T040 [US3] Write the doc comment for `ChatMetrics` recording where the constants came from, in the manner of `PageMetrics`: the two measured pane widths from T038, and the reasoning for the cap
- [X] T041 [P] [US3] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ChatMetricsTests.swift` asserting the four invariants from [contracts/ui.md](contracts/ui.md#invariants-2): `measure > padding * 2` at every pane width (FR-019); `measure <= measureCap` (FR-017); `padding >= tightPadding` (FR-018); and `measure` monotonic in `width` (FR-020), checked by sweeping widths in small steps
- [X] T042 [P] [US3] Add two anchor tests to `ChatMetricsTests.swift`: at the sidebar-open pane width from T038 the text is far wider than the margin (today it is 192pt of text to 288pt of gutter); at the sidebar-shut width `measure` lands near 572, so the default view barely changes

### Applying it

- [X] T043 [US3] Create `Shared/UI/ChatColumn.swift` with `extension View { func chatColumn(paneWidth: Double) -> some View }`, applying `ChatMetrics.forPane(width:)` as horizontal padding, then `frame(maxWidth: measure + padding * 2)`, then `frame(maxWidth: .infinity, alignment: .center)` so the surplus splits either side (FR-020)
- [X] T044 [US3] In `App/Sources/Chat/Transcript.swift`, replace `.padding(.horizontal, 144)` at line 62 with `.chatColumn(paneWidth:)` fed from a `GeometryReader` or `onGeometryChange` on the pane, and change the trailing `.frame(maxWidth: .infinity, alignment: .leading)` at line 64 to centred. Keep the vertical padding and the `bottomInset` handling untouched
- [X] T045 [US3] In `App/Sources/Chat/PromptBar.swift`, replace `.padding(.horizontal, 144)` at line 97 with the same `.chatColumn(paneWidth:)`, fed from the same measurement, so the two edges cannot be changed independently (FR-021). Remove the comment at `Transcript.swift:61` that explains the two hard-coded numbers and replace it with one naming the shared modifier
- [ ] T046 [US3] Verify FR-023: scroll to the middle of a long transcript, then toggle the right sidebar, resize the window, and collapse the project list. The reader's position must not move in any of the three
- [ ] T047 [US3] Walk [quickstart.md §5](quickstart.md#5-size-and-measure-by-eye) for measure: narrow, default with sidebar open, wide, and dragging continuously. Confirm no jump at any width and that the prompt bar tracks the transcript

**Checkpoint**: The chat fits its pane at every width. SC-009, SC-010 and SC-011 met.

---

## Phase 6: User Story 4 - The rules are written down (Priority: P2)

**Goal**: Three checks that fail when somebody writes a literal instead of using the shared definition.

**Independent Test**: Break one call site of each kind and watch the matching check fail, naming the file and line.

**Approach**: Source scans, because neither app has a test target. `MarkdownBlockTests.swift:256` already walks `#filePath` up to the repo root; `LegacyRecordTests` and `ReplayTests` do the same.

- [X] T048 [US4] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift` with a helper that locates the repo root from `#filePath` and returns every `.swift` file under `App/Sources` and `Remote/Sources`, following the pattern at `MarkdownBlockTests.swift:256`
- [X] T049 [P] [US4] Add the colour check (FR-024): no `.red`, `.orange`, `.green` or `Color.accentColor` appearing in a `foregroundStyle`, `fill` or `stroke` outside `Shared/UI/StateTint.swift`. Allow-list `Remote/Sources/Chat/EntryView.swift:329` by name with a comment saying why — it is a control, not a state (FR-006b)
- [X] T050 [P] [US4] Add the type-scale check (FR-025): no `.font(` literal in the transcript entry renderers — `Transcript.swift`, `EntryView.swift`, both `BlocksView.swift`, both `MarkdownText.swift`, both `PlanView.swift`, `DiffView.swift`, `CommandList.swift`, `AttachmentStrip.swift` — except markdown headings, which are allow-listed by name
- [X] T051 [P] [US4] Add the measure check (FR-026): no `.padding(.horizontal, <number>)` in `App/Sources/Chat/Transcript.swift` or `App/Sources/Chat/PromptBar.swift`
- [X] T052 [US4] Prove each check bites rather than passing vacuously, per [quickstart.md §2](quickstart.md#2-the-call-site-checks): put a literal back in a call site, run `swift test --filter Consistency`, confirm it fails and names the file, then `git checkout` the file. Do this for all three. A check that matches nothing is a green test that protects nothing
- [X] T053 [US4] Make each failure message say what to use instead, not just that something matched — the next person to hit it should not have to read the test to know the fix

**Checkpoint**: SC-007 met. The three earlier stories cannot silently rot.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T054 Run the full suite: `cd Packages/AgentsKit && swift test`. `AgentGroupTests`, `PageMetricsTests` and the outcome suites must be unchanged — grouping and outcomes are not this feature's subject
- [X] T055 [P] Confirm FR-027: no wording, icon or accessibility label changed anywhere in the diff. `git diff` and read every changed line that is not a colour, a font or a padding
- [X] T056 [P] Update `Remote/Sources/ReadableWidth.swift`'s doc comment, which currently describes the Mac's 144pt gutter as the thing it deliberately is not doing. That gutter no longer exists
- [X] T057 [P] Record in [research.md §7](research.md#7-follow-on-work-deliberately-not-in-this-feature) that `PageMetrics` still wants moving to `AgentsKitCore` so the phone's document pane stops re-deriving its own numbers, and that `Remote/Sources/Chat/DocumentView.swift:14` is the comment that will need deleting when it happens
- [ ] T058 Walk [quickstart.md](quickstart.md) end to end on both apps, including §6 accessibility text
- [X] T059 Confirm every measurable outcome SC-001 through SC-011 in [spec.md](spec.md#measurable-outcomes), and note any that could not be checked and why

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies. T001 → T002 → T003 in order
- **Foundational (Phase 2)**: Needs Phase 1. Blocks US1 only
- **US1 (Phase 3)**: Needs Phase 2
- **US2 (Phase 4)**: Needs Phase 1 only — T025 creates its own type. Independent of US1
- **US3 (Phase 5)**: Needs Phase 1 only. Independent of US1 and US2. Do last of the three
- **US4 (Phase 6)**: Needs whichever stories it checks to be finished. T049 needs US1, T050 needs US2, T051 needs US3
- **Polish (Phase 7)**: Needs everything

### Within Each User Story

- US1: T004–T006 before any call site. T007–T022 are all parallel — different files, one mechanical change each. T023–T024 last
- US2: T025 before everything else in the phase. T026–T034 parallel. T035–T037 last
- US3: T038 before T039. T039–T040 before T041–T042. T043 before T044–T045. T046–T047 last
- US4: T048 before T049–T051. T052–T053 last

### Parallel Opportunities

- **Phase 3 is almost entirely parallel**: T007 through T022 are sixteen independent single-file edits
- **Phase 4**: T026 through T034 are nine independent file edits once T025 lands
- **US1, US2 and US3 can run concurrently** after Phase 1, by three people or three agents
- T041 and T042 write to the same file and must not both be in flight

---

## Parallel Example: User Story 1

```bash
# After T004-T006, the sixteen call-site edits go at once:
Task: "Move AgentRow.swift tint to StateTint"
Task: "Move Transcript.swift:364 to StateTint.attention"
Task: "Move WorkflowRow.swift:103 to StateTint.attention (red → orange)"
Task: "Move ProjectRow.swift:33 dot to StateTint.attention (accent → orange)"
Task: "Move AgentCard.swift tint to StateTint (accent → orange)"
Task: "Move ProjectListView.swift:56 dot to StateTint.attention"
Task: "Move EntryView.swift:143 to StateTint.attention"
Task: "Move ArtifactsPane.swift:57 to StateTint.failure (orange → red)"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 — `Shared/UI` exists and both apps build
2. Phase 2 — `StateTint` compiles, nothing uses it
3. Phase 3 — every call site moved
4. **Stop and look at it.** One colour per meaning is the reported problem and the whole of SC-001

### Incremental Delivery

Each story is a separate, runnable increment, and each leaves the app shippable:

1. Setup + Foundational → nothing visible
2. + US1 → colour agrees everywhere (MVP)
3. + US2 → the chat stops reading small
4. + US3 → the chat fits its pane
5. + US4 → none of it can rot

### Ordering note

US3 is P1 and answers the most visible complaint, but it carries the scroll-position risk
and should still go last of the three. US1 and US2 are mechanical; US3 is the one that
might take a day.

---

## Notes

- Sixteen of the colour tasks are one-line mechanical edits. The judgement was spent in
  [research.md §4](research.md#4-the-full-colour-inventory), which classified every site
- Six sites change colour: four to orange (T009–T014), three to red (T020–T022). Everything
  else routes an unchanged colour through the shared definition
- Commit per task or per logical group; every checkpoint is a place to stop
- Do not pattern-kill `agentsd` when restarting to look at something — take the pid from the
  target root's `daemon.lock`

---

## Implementation Notes (2026-09-19)

Everything buildable is built: both apps compile, `swift test` passes 805 tests in 92
suites, and each of the three checks was proved to bite and name its file and line.
The tasks left unchecked — T024, T036, T037, T046, T047, T058 — are the by-eye walks
in [quickstart.md](quickstart.md) §4–§6, which want a person in front of both apps.
This session runs inside the Agents app, so launching a second copy to look was not
done.

Where the code differed from the plan:

- **Five gutter sites, not two.** `PermissionView.swift`, `ElicitationView.swift` and
  `ProjectAgentsView.swift` (which holds the same `PromptBar`) also hard-coded 144.
  Leaving them would have misaligned the floating cards and the project page against
  the bar the moment the bar moved. All five now use `.chatColumn()`, and the measure
  check covers all five files.
- **`chatColumn()` measures the pane itself.** The contract's `chatColumn(paneWidth:)`
  exists and is the arithmetic; the argument-free form wraps it with an
  `onGeometryChange` on its own outer frame, so five surfaces in three parents share
  one measurement without being handed a number.
- **T038's widths are arithmetic on the stored defaults** — 1,100 window, 240 list,
  380 sidebar — not a ruler held to the running app. `ChatMetrics`'s doc comment says
  so. Constants: cap 580, padding 40 down to 16, ramp from 320 to 660. At 480 the text
  is 425 inside 27 a side; at 860 it is 580, against 572 before.
- **Files the plan named that do not exist:** `Remote/Sources/Projects/TotalsView.swift`
  (the phone's spend line is in `RemoteChatView.swift`, moved under T018),
  `Remote/Sources/Chat/PlanView.swift` (the phone's `PlanView` is private inside
  `EntryView.swift`, moved under T029), `Remote/Sources/Chat/DocumentView.swift`
  (see research §7), and the accent-coloured diff button at `EntryView.swift:329`
  (FR-006b). No accent colour exists anywhere in the phone's chat; the colour check's
  allow-list is therefore empty, with the mechanism kept.
- **The colour check is broader than T049 asked.** It flags `.red`, `.orange`, `.green`
  and `.accentColor` on any code line, not only inside `foregroundStyle`/`fill`/`stroke`,
  because `AgentRow`'s tint was a `return .orange` in a computed property and the
  narrower scan would have missed it. Comments are stripped before matching.
- **The measure check has a threshold.** `.padding(.horizontal, N)` is flagged for
  N ≥ 20 or for any non-literal argument; the capsule insets of 10 and 12 inside the
  prompt bar are chrome, not a margin.
- **A fourth check** (`noChatTextIsPinnedToAPointSize`) enforces FR-015 directly: every
  `.system(size:)` under either chat directory must sit under a `// Decorative:` line.
- **`AgentsKitCore` gained `UI/ChatMetrics.swift`** with no `import SwiftUI`; the
  daemon still links no UI.

SC status: SC-001, SC-003, SC-004, SC-007, SC-009, SC-010 and SC-011 hold by
construction and by test. SC-002, SC-005, SC-006 and SC-008 need a person and are
carried by the unchecked walks above.
