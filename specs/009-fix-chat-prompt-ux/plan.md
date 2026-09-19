# Implementation Plan: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Branch**: `009-fix-chat-prompt-ux` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/009-fix-chat-prompt-ux/spec.md`

## Summary

Seven reported bugs. The research turned the first into six of its own, found the second already
written and correct but unreachable, the third into a binding whose getter and setter disagree
about where the truth is, the fourth into an affordance the transcript already has all the
state for, the fifth into about forty lines, the sixth from a daemon record change into four client-side
lines, and the seventh into "draw it the way the view twelve lines away already draws it".

The controls under the prompt vanish because `PromptBar.options` is an `if` with no `else`, and
six different things upstream can hand it an empty list: Cursor advertises no options at all
and always will; the `??` fallback cannot fire on an empty array; a failed fetch is
indistinguishable from no options and nothing offers a retry; two overlapping fetches let the
loser win; three daemon sites write an empty options list into the saved record where
`ACPSession.setOption` already knows to guard against exactly that; and the row is measurably
wider than the pane it sits in. That last one is the one you can see: Claude's new-chat row
needs a 693pt conversation pane, and dragging the sidebar past 407pt of the default 1100pt
window takes the model and thought-level controls off the right-hand edge with no indication
that they went.

So the fix is a total state — `PromptControlsState`, six cases, switched over exhaustively —
plus the five upstream repairs and a horizontal scroll view. The state is a pure function in
`AgentsKitCore` with a test that the switch is total, because that is the thing that stops a
seventh cause from re-opening this bug silently in a year.

An option control on a live agent does not respond to a click because
`PromptBar.binding(for:)`'s getter reads `agent.startOptions` while its setter writes only to a
`Task`. The draft branch beside it writes somewhere the getter reads, which is why a new chat
is already instant. So the fix is an optimistic value — `pendingOptions[agentID][optionID]`,
written synchronously before the call, read first by the getter, dropped when the answer
arrives. The daemon already broadcasts `changed(agent)` before it returns, so the record
carries the new value by then and there is no snap-back; two clicks in a row need the same
generation token as cause 4 above, so the first call completing does not clear the second's
value.

Clicking a project does not take you to the project because of a framework detail, not a
missing rule. `AppModel.selectedProject.didSet` already clears `selection` with the comment
"Picking a project shows the project, not a conversation" — but a macOS `List` selection binding
only fires on a *change*, and when you are inside a conversation the highlighted project is
already that conversation's project. The click you would make to go up is the one `NSTableView`
discards. So the fix is to stop treating "go to this project" as a side effect of a selection
change and make it an intent: `AppModel.showProject(_:)` that clears `selection`
unconditionally, called from a `simultaneousGesture` on the row, which is the one gesture form
that coexists with `List` selection rather than replacing it.

Getting back to the end of the conversation needs no new machinery at all. `Transcript` already
computes `fromBottom` and `canScroll` every frame in `onScrollGeometryChange` and already keeps
`isAtEnd`; it just never shows any of it. A button in an overlay, a `hasNewBelow` flag, a scroll
token on `AppModel` so `send()` can ask for the end, and a menu command for the keyboard.

An agent that shows a file while you are reading a different conversation currently tells
nobody. Both halves of that are deliberate — the daemon stores nothing, and the window will not
pull itself away from what you are reading — and the gap is between them. The tempting fix is
to put the agent in `waitingOnUser`, which would be a bug: that state means `holdsRuntime` and
`hasTurnInFlight`, so prompts would start queueing, and the transition table has no way back
out of it except answering a permission. The mark is therefore not a state. Nor does it need a
daemon record: `AgentsModel.filesToShow` is already the unseen-file flag, already keyed by
agent, already cleared at the right moment by opening the conversation. `AgentGroup` takes a
second input, `agents(in:group:)` passes it, and `ProjectRow` ors it into its dot. Four places,
no wire change.

Remembering the mode is the small one, and the research confirmed the cheap route works:
`DaemonCore.start` already calls `session.apply(request.startOptions)`, so seeding `draftChosen`
from a remembered value is enough — no daemon method, no protocol change. One `UserDefaults`
key, and the only part that can be wrong — *is this remembered value still one the runtime
offers?* — is a pure function in the package where `swift test` can reach it.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: None added. SwiftUI and Foundation only. No new package, no new
target.

**Storage**: One new `UserDefaults` key, `prompt.mode.<runtimeID>`, holding the mode value last
chosen for that runtime. The project navigation fix writes nothing new — `selectedProjectFolder`
already exists and keeps its current meaning. No file, no schema, no migration, nothing written to a project folder.
The daemon stores nothing new — the three daemon changes are guards on existing assignments.

**Testing**: `swift test` in `AgentsKit`. `AgentGroupTests` already exhausts the state-to-group
mapping and must be widened to exhaust the new `wantsEyes` input rather than weakened — an
agent in two groups or none is the failure it exists to catch. The project navigation fix has
nothing pure to test —
it is a gesture on a view and a two-line method on `AppModel`, neither reachable from the
package's test target — so it is checked by running the app, and `quickstart.md` names the exact
click. Two new unit suites: `PromptControlsStateTests` and
`ModeMemoryTests`. The two tests that carry the feature are that the state switch is **total**,
because an unhandled case is the bug returning, and that a remembered mode a runtime no longer
offers is dropped rather than sent, because that is the one place this feature could start an
agent in a mode the person did not choose. `ConfigOptionTests` is the existing regression suite
for the option shapes and must pass unchanged. There is no app test target and no snapshot test
in this repository, so the views are checked by running the app; `quickstart.md` says how,
including the exact sidebar width at which the row currently breaks.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: None of this is on a hot path. The one thing to not get wrong is the
jump-to-end button's visibility, which is driven by the `onScrollGeometryChange` closure that
already runs every frame — the additional work is two comparisons on a struct that is already
`Equatable`, so SwiftUI coalesces the no-change case as it does today.

**Constraints**: An optimistic value must never outlive the call that produced it, and must
never be mistaken for what is in force — FR-034 and FR-035 exist so that a runtime's refusal is
visible rather than papered over. No layout that measures its own width and picks a layout from it — a custom
`Layout` and `ViewThatFits` have each crashed this app through AppKit, and the comment in
`PromptBar.options` records both. No colour literal; the house rule is that colour means
something has gone wrong, and none of this is an error. No new dependency. No new ACP call and
no new daemon method. The transcript's existing behaviour — opens at the end, follows while the
reader is at the end, keeps the reader's place when earlier history loads — must survive
unchanged, which is what FR-010 and FR-014 are for.

**Scale/Scope**: 43 functional requirements over 7 user stories. Six causes behind one symptom,
two new types, one new `UserDefaults` key, one new menu command, one new gesture, two
generation tokens, one extra input to an existing enum, and one deliberate visual regression
(the options row loses its right-alignment to gain a scroll view).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been
written for this project, by the user's explicit decision, so there is nothing to check against
and no violation can be claimed. The rules in force are the ones 001 through 008 recorded.

| Rule in force | Where the design honours it |
|---|---|
| Logic where `swift test` can reach it | `PromptControlsState` and `ModeMemory` are pure types in `AgentsKitCore`. The views switch over an answer; they do not compute it |
| One code path, no per-kind branching | One state for the control area, covering every runtime. Cursor is not special-cased; it is the `.nothingOffered` case, which any runtime can be in |
| Two versions of one question are answered the same way | A one-choice elicitation is drawn the way `PermissionView` already draws a permission question: the agent's wording, on buttons, answered outright |
| Say plainly when something cannot be done | The whole of User Story 1. Six ways to have no controls, and each one now says which it is, in the reader's language |
| Nothing installed, nothing added | No package, no target, no daemon method, no protocol change |
| Colour means something is wrong | The jump-to-end button and the new control-area messages use `.secondary`/`.tertiary` and typography. Only the fetch-failed case may carry the app's existing error treatment |
| The daemon owns what outlives windows | The mode preference is a habit about this Mac, so it is `UserDefaults` beside `sidebar.*`, not a daemon record. `SidebarFrame`'s own comment draws this line |
| An agent asking for something is a request | Unchanged. Nothing here lets a runtime move the reader's scroll position; new lines arriving while the reader is scrolled up still do not move the pane (FR-010) |
| A client never edits the daemon's record | The optimistic option value lives in its own short-lived map, not written into `agent.startOptions`, so the client can never quietly disagree with the daemon |
| Where the window is looking is not what is true about the work | `showProject` moves the window and touches no agent. FR-025 makes that a requirement rather than an accident |
| An agent asking to be looked at is a request, not a command | Story 5 marks it and leaves the window where the person put it. FR-031 keeps today's immediate behaviour for the conversation already on screen |
| Nothing is stored that should not outlive the window | Story 5 adds no record field and no daemon method. `showFile`'s "this goes out as an event and is gone" stands |
| Fix the guard that already exists elsewhere | Three unguarded `advertisedOptions = await session.options` assignments get the `if !refreshed.isEmpty` guard that `ACPSession.setOption` already has |

**Re-check after Phase 1**: unchanged. The design adds two value types to a package that
already holds the option model, one defaults key, one overlay, one menu command and a
generation counter. It removes no capability and adds no surface anyone outside the app can
reach.

## Project Structure

### Documentation (this feature)

```text
specs/009-fix-chat-prompt-ux/
├── plan.md                        # This file
├── spec.md                        # What it does
├── research.md                    # The six causes with the measurements, the unreachable click,
│                                  #   the lagging binding, and why a shown file is not a state
├── data-model.md                  # Phase 1 output
├── quickstart.md                  # Phase 1 output — how to see each bug, and each fix
├── contracts/
│   ├── prompt-controls-state.md   # The AgentsKitCore surface the control area switches over
│   └── mode-memory.md             # Remembering and resolving the mode
├── checklists/
│   └── requirements.md            # Spec quality gate (passed)
└── tasks.md                       # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
└── Model/
    ├── Options.swift              # Touched: `modeOption` lookup by category
    ├── AgentGroup.swift           # Touched: `init(for:wantsEyes:)`, the old init kept
    ├── ElicitationSchema.swift    # Touched: `singleChoice`, the one-click condition
    ├── PromptControlsState.swift  # New. Six cases and the one function that picks one
    └── ModeMemory.swift           # New. Resolve a remembered value against what is offered

Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+Commands.swift      # Touched: guard the assignments at :61 and :283
└── DaemonCore+Runtimes.swift      # Touched: guard the assignment at :132

App/Sources/
├── AgentsApp.swift                # Touched: a `.commands` block for the keyboard route
├── AppModel.swift                 # Touched: fetch generation, options for a started agent,
│                                  #   the scroll-to-end token, the mode preference store,
│                                  #   `showProject(_:)`, and the pending option values
├── Projects/
│   ├── ProjectRow.swift           # Touched: the tap that always goes to the project,
│   │                              #   and the dot an unseen file also lights
│   └── ProjectListView.swift      # Touched only if the row cannot carry the gesture
├── Elicitation/
│   └── ElicitationView.swift      # Touched: a one-choice form is a row of buttons
└── Chat/
    ├── PromptBar.swift            # Touched: switch over the state; scroll the row; send scrolls
    ├── Transcript.swift           # Touched: hasNewBelow, the overlay, the token
    └── JumpToEnd.swift            # New. The button, and nothing else

Packages/AgentsKit/Tests/AgentsKitTests/Unit/
├── AgentGroupTests.swift          # Touched: exhaust the new input too
├── ElicitationSchemaTests.swift   # Touched: which forms are one-click and which are not
├── PromptControlsStateTests.swift # New. Totality, and one test per cause
└── ModeMemoryTests.swift          # New. Resolve, drop-when-stale, per-runtime isolation
```

**Structure Decision**: No new target and no new module. The two new types go into
`AgentsKitCore/Model/` beside `Options.swift`, because they are about options and because
`AgentsKitCore` is the half of the package that both platforms link — the phone's prompt bar
will want the same state when it grows one. The view work stays in `App/Sources/Chat/`. The
daemon changes are three lines in two existing files.

## Complexity Tracking

No Constitution Check violations. One design cost is recorded here because it is a visible
regression rather than a violation:

| Cost | Why accepted | Alternative rejected because |
|---|---|---|
| The options row loses its right-alignment: permission controls, a fixed 16pt gap, then the rest, inside a horizontal scroll view | It is the only arrangement that keeps every control reachable at 232pt of content without measuring width and picking a layout from the measurement | A custom `Layout` and `ViewThatFits` have each crashed this app through AppKit; the comment in `PromptBar.options` records both. A collapsing overflow menu still needs the width measurement it would be there to avoid |
| A gesture on a `List` row alongside the row's own selection | There is no other way to observe a click on an already-selected row: the selection binding is driven by a *changed* notification and never fires | Intercepting the binding's setter does not help for the same reason. Making the row a `Button` and keeping `List(selection:)` for the highlight is the fallback if `simultaneousGesture` is swallowed — it is second choice because it fights the sidebar's own styling |
