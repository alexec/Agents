# Quickstart: Visual Consistency

**Feature**: 018-visual-consistency | **Date**: 2026-09-19

How to prove this landed. Two halves: numbers a test can hold, and a look only a person
can confirm. Both are needed — the whole feature exists because something looked wrong.

## Prerequisites

```sh
cd /Users/alexcollins/Agents
xcodegen generate          # Shared/UI is new; the project must be regenerated
```

The daemon is already running as the host of these sessions. Do not pattern-kill it; if it
must be restarted, take the pid from the target root's `daemon.lock`.

## 1. The arithmetic

```sh
cd Packages/AgentsKit && swift test --filter ChatMetrics
```

Expect the four invariants from [contracts/ui.md](contracts/ui.md#invariants-2):

- text beats margin at every pane width
- the column never exceeds the cap
- the padding never falls below its floor
- `measure` is monotonic in `width`

Then the two anchors that make it the right cap rather than merely a consistent one:

- at a 480pt pane — the default window with the right sidebar open — `measure` is
  comfortably more than `padding * 2`, against 192pt of text and 288pt of gutter today
- at an 860pt pane — the default window with the sidebar shut — `measure` lands near 572,
  so the default view barely changes

## 2. The call-site checks

```sh
cd Packages/AgentsKit && swift test --filter Consistency
```

Three scans over `App/Sources` and `Remote/Sources`. To confirm each actually bites rather
than passing vacuously, break one and watch it fail:

```sh
# Put a literal back and re-run — the first check must fail, naming the file and line.
sed -i '' 's/StateTint.attention/Color.red/' App/Sources/Projects/WorkflowRow.swift
cd Packages/AgentsKit && swift test --filter Consistency    # expect failure
git checkout App/Sources/Projects/WorkflowRow.swift
```

Repeat for a stray `.font(.footnote)` in `App/Sources/Chat/BlocksView.swift` and a
`.padding(.horizontal, 144)` in `Transcript.swift`.

## 3. The whole suite

```sh
cd Packages/AgentsKit && swift test
```

Nothing in `AgentGroupTests`, `PageMetricsTests` or the outcome suites may change.
Grouping and outcomes are untouched by this feature.

## 4. Colour, by eye

Build and run the Mac app. Put one project into a state with all four at once:

- an agent waiting on a permission question → **orange**
- an agent that reported `stuck` or `needsAnswer` → **orange**
- an agent that reported `done` → **green**
- a project whose folder has been moved on disk → **red**
- an agent at its cost limit → **red** (was orange)

Check every surface shows the same agent the same colour: the agent list, the project row's
dot, the project page heading, the workflow row, and the chat transcript. Then open the
Remote on a phone or simulator against the same daemon and check all five again. The dot on
a project row must be orange, not the system accent colour.

Turn the system accent colour to orange in System Settings and confirm a waiting agent is
still distinguishable from an ordinary control (FR-005). Then switch to dark mode and check
all three colours again (FR-008).

Finally, turn colour off in your head: every one of those states must still be readable
from its icon and words alone (FR-007).

## 5. Size and measure, by eye

Open a long conversation containing prose, a thought, a tool call, a code block, a diff, an
attachment and an image the app cannot draw.

- Nothing on the page is two steps smaller than the thing above it for no reason.
- The same transcript on the phone puts each entry kind at the same relative step.
- Compare the Mac's and the phone's `BlocksView` placeholders directly — these disagreed
  before.

Then drag the window:

- **Narrow.** Text keeps the space; the margin gives way. It never collapses.
- **Default, sidebar open.** More text than margin. This is the reported symptom; it is the
  one to look at hardest.
- **Wide.** The column stops growing and centres, surplus split either side.
- **Dragging.** The column grows smoothly. No jump at any width.
- **Prompt bar.** Its edges line up with the transcript's at every width.

Scroll to the middle of the transcript, then toggle the right sidebar. The reader's
position must not move (FR-023).

## 6. Accessibility text

Raise system text size to its largest setting. Every part of the transcript scales; nothing
is pinned. No row clips — long rows wrap or truncate with a tooltip. The column ceiling
still holds, with fewer words per line rather than a cut-off column (FR-022).

## What would mean it has not landed

- A count of distinct "needs a person" colours other than one (SC-001).
- Orange anywhere that does not need a person (SC-001).
- Any pane width where margin beats text (SC-009).
- The transcript and the prompt bar disagreeing on where the left edge is (SC-010).
