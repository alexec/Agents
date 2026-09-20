# Research: Visual Consistency

**Feature**: 018-visual-consistency | **Date**: 2026-09-19

Everything here was read out of the codebase rather than looked up. The three questions
the plan had to answer were: where can code that both apps use actually live, does the
measure problem already have an answer in this repo, and how do you test any of it when
neither app has a test target.

## 1. Where shared UI code can live

**Decision**: A new `Shared/UI/` source directory, listed in both the `Agents` and
`Remote` targets in `project.yml`. Pure-arithmetic types go in `AgentsKitCore` instead.

**Rationale**: The two apps are separate Xcode targets with disjoint sources
(`App/Sources`, `Remote/Sources`) and no shared view code at all today — `MarkdownText`
and `BlocksView` exist twice over, which is why they drifted apart on font sizes. Both
targets link `AgentsKitCore`, and that package builds for both platforms. But
`AgentsKitCore` contains no `import SwiftUI` anywhere, and `agentsd` links it through
`AgentsKit`: putting `Color` in the package would make the daemon link SwiftUI. XcodeGen
lets one source path appear in two targets, which gives one file compiled into both apps
with SwiftUI available in each.

**Alternatives considered**:
- *SwiftUI types in `AgentsKitCore`*. Rejected: drags SwiftUI into the daemon's
  dependency graph for the sake of three colours.
- *Duplicate in both apps, test that the copies match*. Rejected: it is the status quo
  with a test bolted on, and the test can only compare text, not meaning.

## 2. The measure problem is already solved here

**Decision**: Model the chat measure on `PageMetrics`, and put the chat's version in
`AgentsKitCore` so both apps can use it.

**Rationale**: `Packages/AgentsKit/Sources/AgentsKit/Files/PageMetrics.swift` is this
exact problem, solved for the document pane by feature 007. It has a measure cap, a
padding floor, and — the part worth copying — the padding *ramps* between two pane widths
rather than stepping, because a step "would make the measure jump outwards as the pane got
narrower … which reads as a glitch while somebody is dragging the resize handle." Its
comment states the property that matters: `measure` stays monotonic in `width`. That is
FR-017 through FR-020 already worked out, with `PageMetricsTests` pinning the numbers.

`PageMetrics` lives in `AgentsKit`, the Mac-only target. `Remote/Sources/Chat/DocumentView.swift:14`
says so explicitly: "`PageMetrics` is not used here. It lives in `AgentsKit`, which the
Remote does not…". So the document pane on the phone already re-derives its own numbers.
That is the same drift 018 exists to stop, one feature earlier.

**Alternatives considered**:
- *Reuse `PageMetrics` directly for chat*. Rejected: its numbers are for a 12pt document
  face in a 280–380pt sidebar. Chat is body text in a pane several times wider. Same
  shape, different constants.
- *Move `PageMetrics` to Core as part of this work*. Rejected as scope: it would fix the
  phone's document pane too, and that is a real improvement, but it is not what 018 was
  asked to do. Recorded below as follow-on work.

## 3. Testing, when neither app has a test target

**Decision**: Put the arithmetic in `AgentsKitCore` and unit-test it there. Enforce the
call-site rules (FR-024–FR-026) with a source-scanning test in `AgentsKitTests` that walks
up from `#filePath` to the repo root and reads `App/Sources` and `Remote/Sources` as text.

**Rationale**: `project.yml` declares one test target, `AgentsKit/AgentsKitTests`, inside
the package. It cannot import the app targets. But the pattern for both halves already
exists in the suite:
- *Arithmetic in the package, applied by the view*: `PageMetrics` with `PageMetricsTests`,
  and `FilesPaneScaleTests`. The view does no maths of its own.
- *Tests reading repo files*: `MarkdownBlockTests.swift:256` walks `#filePath` up four
  levels to the repo root; `LegacyRecordTests` and `ReplayTests` do the same.

So a test that asserts "no file under `App/Sources` or `Remote/Sources` contains a literal
state colour outside the shared definition" is a text scan, and text scans of the repo are
established practice here.

**Alternatives considered**:
- *A shell script in `scripts/`*. Rejected: `scripts/` holds one hand-run diagnostic
  (`acp-handshake.sh`) and nothing wires it to a build. A test runs with `swift test` and
  with the Xcode scheme, which is where failures will actually be seen.
- *Adding test targets for the apps*. Rejected as disproportionate: a whole new target and
  scheme to hold three lint assertions.

## 4. The full colour inventory

Read from source. This is what the plan has to move.

**Attention — must end up orange (FR-003):**

| Site | Today |
|---|---|
| `App/Sources/AgentList/AgentRow.swift:175,179` | `.orange` ✓ |
| `App/Sources/Chat/Transcript.swift:364` | `.orange` ✓ |
| `App/Sources/Projects/WorkflowRow.swift:103,215` | `Color.red` ✗ |
| `App/Sources/Projects/ProjectRow.swift:33` | `Color.accentColor` ✗ |
| `Remote/Sources/Chat/EntryView.swift:143` | `Color.accentColor` ✗ |
| `Remote/Sources/Projects/AgentCard.swift:176,177` | `.accentColor` ✗ |
| `Remote/Sources/Projects/ProjectListView.swift:56` | `Color.accentColor` ✗ |

The two `ProjectRow`/`ProjectListView` sites are the small filled dot drawn when
`needsPerson` / `summary.needsInput`. They are attention indicators drawn in the accent
colour, which FR-005 forbids.

**Failure — red, and staying red:** `ProjectAgentsView.swift:68` and
`ProjectPageView.swift:125` (folder gone); `CostSettingsView.swift:82`,
`ProjectListView.swift:201`, `TotalsView.swift:91` (spend); `ContextMeter.swift:30,73`,
`RemoteChatView.swift:236,246` (context full); `Transcript.swift:611`,
`EntryView.swift:276` (failed call); `PlanView.swift:74,77`; `AttachmentStrip.swift:22`;
`ElicitationView.swift:221`; `RuntimeAccountView.swift:25`.

**Orange spent on something else — moving to red (FR-006a):**
`ArtifactsPane.swift:57` (artifact no longer there), `CostSettingsView.swift:175` (warning
while setting a limit), `PromptBar.swift:153` (agent at its cost limit).

**Green — staying (FR-002):** `AgentRow.swift:176`, for an agent that reported `done`
itself. Feature 014 gave it that deliberately.

**Out of scope (FR-006b):** `EntryView.swift:329` is an accent-coloured button that opens
a diff. A control, not a state.

## 5. The chat type scale

`App/Sources/Chat/` and `Remote/Sources/Chat/` choose a size at roughly sixty call sites
between them, with no ambient font set by either `ChatView` or `RemoteChatView`. The
spread is four steps: prose falls through to the platform default (`.body`), supporting
content is `.callout`, placeholders in the Mac's `BlocksView` are `.footnote` where the
phone's are `.callout`, and fine print is `.caption`/`.caption2`.

Two fixed point sizes exist in chat and must go under FR-015: `AttachmentStrip.swift:16,29`
and `PromptBar.swift:691`, `JumpToEnd.swift:18`, `SelectCapsule.swift:22,64`. Those on
glyphs inside capsules are decorative and exempt; the ones on text are not.

## 6. The chat gutter

`Transcript.swift:62` and `PromptBar.swift:97` each hard-code `.padding(.horizontal, 144)`,
with a comment on the first saying it "lines up with the prompt bar below it". Two numbers
that must agree, with nothing making them.

The chat pane does not get the window: `ContentView.swift:51-61` puts `ChatView` and
`SidebarView` in an `HStack`, and the project list takes 200–320 (`ContentView.swift:46`).
At the default 1100pt window (`AgentsApp.swift:12`) with the sidebar at its stored default
of 380 (`SidebarState.swift:79`), the chat pane is roughly 480pt — of which 288 is gutter
and 192 is text. That is the reported symptom, reachable at default settings.

## 7. Follow-on work, deliberately not in this feature

- `PageMetrics` should move to `AgentsKitCore` so the phone stops re-deriving its own
  numbers. Same class of problem, different feature. The phone's copy is
  `Remote/Sources/ReadableWidth.swift`, a fixed 620-point ceiling with no ramp and no
  test; its doc comment now names this as the follow-on. (The plan referred to a
  `Remote/Sources/Chat/DocumentView.swift` with a comment to delete — no such file
  exists; `ReadableWidth.swift` is the one that carries the note.)
- `AgentsModel.agents(in:group:)` promises "newest activity first" and applies no sort.
  Belongs to 019, and is noted there.
