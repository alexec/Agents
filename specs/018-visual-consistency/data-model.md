# Data Model: Visual Consistency

**Feature**: 018-visual-consistency | **Date**: 2026-09-19

Nothing here is persisted, sent over the wire, or stored on an agent. These are the three
definitions that replace numbers and colours currently written out at call sites, plus the
one existing model type they read from.

## StateTint

The colour vocabulary, as a closed set. Lives in `Shared/UI/StateTint.swift`, compiled into
both apps.

| Case | Meaning | Colour |
|---|---|---|
| `attention` | A person is needed | orange |
| `failure` | Broken, and not actionable from here | red |
| `vouched` | A completion the agent reported itself | green |
| `none` | Everything else | inherits (`.secondary` / `.tertiary` at the call site) |

**Rules**

- The mapping from case to colour is defined once and is the only place a state colour is
  named. (FR-001, FR-002)
- `attention` is never the system accent colour. (FR-005)
- A call site chooses a *case*, never a colour. (FR-001)
- `none` carries no colour of its own; it resolves to whatever secondary or tertiary style
  the surface already uses, so this feature does not flatten existing hierarchy. (FR-006)
- Every case must be legible in light and dark on both platforms. (FR-008)

**Derivation.** One function turns an agent into a tint, so no surface decides for itself:

```
tint(for agent) =
    attention   if agent.needsAPerson
    vouched     if agent.state == .finished && agent.report?.outcome == .done
    none        otherwise
```

`Agent.needsAPerson` already exists (`AgentGroup.swift:100`) and already means exactly
this — `state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson)`.
It is not redefined here; it is the input.

`failure` is not derived from an agent. It is chosen by surfaces describing a condition —
a folder gone, a limit reached, a call that failed — and has no single predicate.

## ChatTypeScale

The four steps a chat entry may be drawn at. Lives in `Shared/UI/ChatTypeScale.swift`.

| Step | Used for | Mac | Phone |
|---|---|---|---|
| `prose` | Agent and person messages | `.body` | `.body` |
| `supporting` | Thoughts, tool titles, the app's question, resource links, placeholders | `.callout` | `.callout` |
| `fine` | Timestamps, block labels, language tags, metadata | `.caption` | `.caption` |
| `code` | Code blocks, diffs, command names | `.callout.monospaced()` | `.callout.monospaced()` |

**Rules**

- Each entry kind names a step; no entry names a font. (FR-009)
- `prose` is the platform's standard reading size. (FR-010)
- `supporting` is exactly one step below `prose`. (FR-011)
- `fine` is at most two steps below `prose`. (FR-012)
- The same entry kind resolves to the same step on both platforms. (FR-013)
- `code` sits one step below its surrounding prose, consistently. (FR-016)
- No step may be a fixed point size. Decorative glyphs inside capsules and badges are not
  text and are exempt. (FR-015)

Today's spread is four steps, because prose falls through to the platform default while
placeholders are `.footnote` on the Mac and `.callout` on the phone. Both collapse into
`supporting`. (FR-014)

## ChatMetrics

How wide the chat's column is allowed to be, and how much margin it keeps. Lives in
`AgentsKitCore` — pure arithmetic, no SwiftUI, so both apps and the test target can use it.

Modelled on `PageMetrics` (`Packages/AgentsKit/Sources/AgentsKit/Files/PageMetrics.swift`),
which solves the same problem for the document pane.

```
ChatMetrics
  measure: Double     // widest the text may run
  padding: Double     // each side

  static measureCap: Double
  static widePadding: Double
  static tightPadding: Double

  static forPane(width: Double) -> ChatMetrics
```

**Rules**

- `measure` is capped; past the cap the surplus becomes margin either side and the column
  centres. (FR-017, FR-020)
- Below the cap the padding gives way before the text does, down to `tightPadding`.
  (FR-018)
- `measure > padding * 2` at every pane width the app can produce. (FR-019)
- Padding ramps between the tight and wide widths rather than stepping, so `measure` stays
  monotonic in `width` and the column does not jump while the window is being dragged.
  This is `PageMetrics`'s property and the reason it ramps; the same reasoning applies.
- `measure` is a ceiling on the column, never on content. Larger accessibility text reflows
  within it. (FR-022)

**Constants.** To be fixed in implementation against the real pane widths, not guessed
here. The two anchors: at the default 1100pt window with the right sidebar open the pane is
about 480pt and must yield far more text than margin; at that window with the sidebar shut
it is about 860pt and should land near today's 572pt of text, so the look at the default
size barely changes.

## Existing types read, not changed

- `Agent.needsAPerson` — the input to `attention`.
- `WorkOutcome.needsAPerson` and `WorkOutcome.done` — the inputs to `attention` and
  `vouched`.
- `AgentGroup` — untouched. Which group an agent is in is 019's subject; this feature only
  changes how the answer is drawn.
