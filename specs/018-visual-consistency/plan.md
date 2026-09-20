# Implementation Plan: Visual Consistency

**Branch**: `018-visual-consistency` | **Date**: 2026-09-19 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/018-visual-consistency/spec.md`

## Summary

Three definitions replace numbers and colours currently written out at roughly eighty call
sites: a closed set of state tints, a four-step chat type scale, and a chat measure that is
a ceiling rather than a gutter. Two of the three already have a working precedent in this
repo — `PageMetrics` for the measure, `AgentGroup` for "derive it once, never store it" —
and the third is the same idea applied to colour.

The hard part is not the arithmetic. It is that `App/Sources` and `Remote/Sources` share no
view code at all today, which is *why* they drifted. So the first piece of work is somewhere
for shared UI code to live, and the last piece is three checks that fail when somebody
writes a literal instead.

## Technical Context

**Language/Version**: Swift 6.0, strict concurrency complete

**Primary Dependencies**: SwiftUI; AgentsKitCore (shared model, builds for both platforms)

**Storage**: None. Nothing in this feature is persisted or crosses the wire.

**Testing**: swift-testing (`@Suite` / `@Test` / `#expect`), one target —
`Packages/AgentsKit/Tests/AgentsKitTests`

**Target Platform**: macOS 27, iOS 27

**Project Type**: Desktop app plus companion iOS app, one shared model package, XcodeGen

**Performance Goals**: The chat column must not jump or stutter while the window is being
dragged. `ChatMetrics.forPane` is called per layout pass and must stay pure arithmetic.

**Constraints**: `AgentsKitCore` must not gain `import SwiftUI` — `agentsd` links it. Neither
app has a test target, so anything to be tested must be arithmetic in the package or a
source scan. Existing wording, icons and accessibility labels are frozen (FR-027).

**Scale/Scope**: ~30 colour call sites, ~60 font call sites, 2 padding sites, across 2 app
targets and 1 package.

## Constitution Check

`.specify/memory/constitution.md` is an unfilled template — every principle is still a
`[PRINCIPLE_N_NAME]` placeholder. There are no ratified gates to evaluate, so none are
claimed as passed.

In their place, the conventions this codebase visibly holds itself to, and how this plan
stands against them:

| Convention, as practised | This plan |
| --- | --- |
| Derive, never store, so two things cannot disagree (`AgentGroup`) | `StateTint.of(_:)` derives from `Agent.needsAPerson`; nothing new is stored |
| Numbers that came from a measurement live in the package under test (`PageMetrics`) | `ChatMetrics` in `AgentsKitCore`, tested like `PageMetricsTests` |
| The daemon links no UI (`AgentsKitCore` has no `import SwiftUI`) | Colours and views go in `Shared/UI`, not the package; only arithmetic goes in Core |
| Colour is rare and means something | Three cases, one meaning each, enforced by a check |
| A comment says why, not what | Each moved call site keeps its existing reasoning |

**Gate result**: nothing to fail. Recorded honestly rather than ticked.

## Project Structure

### Documentation (this feature)

```text
specs/018-visual-consistency/
├── plan.md              # This file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── ui.md            # Phase 1
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks — not created here
```

### Source Code (repository root)

```text
Shared/UI/                                   # NEW — listed in both app targets
├── StateTint.swift                          # the three colours, one mapping
├── ChatTypeScale.swift                      # prose / supporting / fine / code
└── ChatColumn.swift                         # applies ChatMetrics to a view

Packages/AgentsKit/Sources/AgentsKitCore/
└── UI/ChatMetrics.swift                     # NEW — measure arithmetic, no SwiftUI

Packages/AgentsKit/Tests/AgentsKitTests/Unit/
├── ChatMetricsTests.swift                   # NEW — the four invariants
└── ConsistencyTests.swift                   # NEW — three source scans

App/Sources/                                 # ~20 colour sites, ~40 font sites, 2 padding
├── Chat/{Transcript,PromptBar,BlocksView,MarkdownText,...}.swift
├── Projects/{ProjectRow,WorkflowRow,ProjectAgentsView}.swift
├── AgentList/AgentRow.swift
├── Sidebar/ArtifactsPane.swift
└── Settings/CostSettingsView.swift

Remote/Sources/                              # ~10 colour sites, ~20 font sites
├── Chat/{EntryView,BlocksView,MarkdownText}.swift
└── Projects/{ProjectListView,ProjectPageView,AgentCard}.swift

project.yml                                  # Shared/UI added to both targets
```

**Structure Decision**: A new top-level `Shared/UI/` directory, listed under `sources:` in
both the `Agents` and `Remote` targets in `project.yml`. XcodeGen compiles one file into
both apps, and SwiftUI is available on both platforms.

This is the decision the feature turns on. The alternative — putting `Color` in
`AgentsKitCore` — would make `agentsd` link SwiftUI, because the daemon reaches Core through
`AgentsKit`. The package stays free of UI; only `ChatMetrics`, which is arithmetic, goes
there, where the one test target can reach it.

`Shared/UI` is new ground: the two apps currently share no view code, which is exactly how
`MarkdownText` and `BlocksView` came to disagree about font sizes in the first place.

## Phases

**Phase A — somewhere to put it.** `Shared/UI/` and the `project.yml` change, with
`StateTint` in it and nothing using it yet. Ends with `xcodegen generate` and both apps
still building. Nothing visible changes.

**Phase B — colour.** Move every site in the [contract's table](contracts/ui.md#what-each-surface-must-draw)
to a `StateTint` case. Six sites change colour: four to orange, three to red (one file has
two). Green stays where 014 put it. Delivers User Story 1.

**Phase C — type scale.** `ChatTypeScale` plus the `chatText(_:)` modifier, then every
`.font(...)` in both chat directories moved onto a step. Headings excepted. Delivers User
Story 2.

**Phase D — measure.** `ChatMetrics` in Core with its tests, the `chatColumn` modifier, then
`Transcript.swift:62` and `PromptBar.swift:97` moved onto it. Constants pinned against the
two real pane widths from [quickstart §1](quickstart.md#1-the-arithmetic). Delivers User
Story 3.

**Phase E — the checks.** Three source scans in `ConsistencyTests`, each proved to bite by
breaking a call site and watching it fail. Delivers User Story 4.

A, B, C, D each leave the app buildable and runnable. B, C and D are independent of each
other and could go in any order; A must be first and E must be last, because E is what stops
the others rotting.

## Risks

**The measure fighting the scroll position (FR-023).** `Transcript.swift:59-90` does careful
work around `bottomInset`, the floating prompt bar and a `ScrollViewReader`, with comments
explaining that insetting content alone left the scrollbar under the glass. Changing column
width mid-scroll is the kind of thing that fights with it. This is the one part of the
feature that could take a day rather than an hour. Mitigation: do Phase D last of the three
visible phases, and check the sidebar-toggle case explicitly.

**A source scan that passes vacuously.** A regex that matches nothing is a green test that
protects nothing. Mitigation: quickstart §2 requires each check be proved by breaking a call
site, and that is a task, not a suggestion.

**Picking the measure cap by taste.** `PageMetrics` got its 500 from measuring real prose at
a known face and writing the reasoning into the type. `ChatMetrics` should be able to say the
same. Mitigation: pin against the two anchors, and record the reasoning in the doc comment
the way `PageMetrics` does.

**Scope pull toward `PageMetrics`.** Moving it to Core would fix the phone's document pane,
which `Remote/Sources/Chat/DocumentView.swift:14` admits is re-deriving its own numbers. It
is the right change and it is not this feature. Recorded in
[research §7](research.md#7-follow-on-work-deliberately-not-in-this-feature).

## Complexity Tracking

No constitution gates exist to violate. One spec amendment was made during planning rather
than deferred, because the plan could not be written around the contradiction:

| Change | Why | What was rejected |
|---|---|---|
| FR-002 and FR-006 amended to allow green as a third colour | 018 as drafted said only "needs a person" and "broken" may be tinted, which would have deleted the green `done` tint that 014 introduced deliberately (its FR-012). Alex chose to keep it. | Dropping green for a strict two-colour palette; allowing green only in the agent row |
| FR-006a added | Orange was already spent on three non-attention things. Leaving them would have met FR-003 while failing SC-001. Alex confirmed all three move to red. | Leaving them; treating cost-limit states as attention rather than failure |
| FR-006b added | An accent-coloured button that opens a diff is a control, not a state, and a literal-colour check would otherwise flag it. | Silence, and a check that produces a false positive on first run |
