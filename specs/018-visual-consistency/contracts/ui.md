# UI Contract: Visual Consistency

**Feature**: 018-visual-consistency | **Date**: 2026-09-19

What every surface must do, stated so it can be checked. No daemon API changes: nothing
here crosses the wire.

## 1. State colour

### The vocabulary

```swift
// Shared/UI/StateTint.swift — compiled into both Agents and Remote.
enum StateTint {
    case attention   // orange — a person is needed
    case failure     // red    — broken, not actionable from here
    case vouched     // green  — the agent reported `done` itself
    case none        // no colour of its own
}

extension StateTint {
    var color: Color?          // nil for .none
    static func of(_ agent: Agent) -> StateTint
}
```

### What each surface must draw

| Surface | Condition | Tint |
|---|---|---|
| `App/.../AgentList/AgentRow.swift` | `needsAPerson` | `.attention` |
| | outcome `.done` | `.vouched` |
| | anything else | `.none` |
| `App/.../Chat/Transcript.swift:364` | report needs a person | `.attention` |
| `App/.../Chat/Transcript.swift:611` | call failed | `.failure` |
| `App/.../Projects/WorkflowRow.swift:103,215` | wants a person | `.attention` |
| `App/.../Projects/ProjectRow.swift:33` | `needsPerson` dot | `.attention` |
| `App/.../Projects/ProjectAgentsView.swift:68` | folder gone | `.failure` |
| `App/.../Sidebar/ArtifactsPane.swift:57` | artifact gone | `.failure` |
| `App/.../Settings/CostSettingsView.swift:175` | limit warning | `.failure` |
| `App/.../Chat/PromptBar.swift:153` | at cost limit | `.failure` |
| `Remote/.../Projects/AgentCard.swift:176,177` | needs a person | `.attention` |
| `Remote/.../Projects/ProjectListView.swift:56` | `needsInput` dot | `.attention` |
| `Remote/.../Projects/ProjectPageView.swift:125` | folder gone | `.failure` |
| `Remote/.../Chat/EntryView.swift:143` | report needs a person | `.attention` |
| `Remote/.../Chat/EntryView.swift:276` | call failed | `.failure` |

Unchanged and still `.failure`: `CostSettingsView.swift:82`,
`ProjectListView.swift:201`, `TotalsView.swift:91`, `ContextMeter.swift:30,73`,
`RemoteChatView.swift:236,246`, `PlanView.swift:74,77`, `AttachmentStrip.swift:22`,
`ElicitationView.swift:221`, `RuntimeAccountView.swift:25`.

Explicitly out of scope: `Remote/.../Chat/EntryView.swift:329`, an accent-coloured button
that opens a diff. A control, not a state. (FR-006b)

### Invariants

- `StateTint.attention.color != Color.accentColor`. (FR-005)
- Every surface drawing a tint also carries an icon or words for the same state; removing
  colour loses no information. (FR-007)
- Both apps resolve the same case to the same colour, because there is one mapping.

## 2. Chat type scale

```swift
// Shared/UI/ChatTypeScale.swift
enum ChatTypeStep { case prose, supporting, fine, code }

extension View { func chatText(_ step: ChatTypeStep) -> some View }
```

### What each entry kind draws at

| Entry kind | Step |
|---|---|
| Agent message, person message | `prose` |
| Agent thought | `supporting` |
| Tool call title | `supporting` |
| "Agents asked" body | `supporting` |
| Resource link, undrawable image, audio, unknown block | `supporting` |
| Timestamps, language tags, block labels, per-entry metadata | `fine` |
| Code blocks, diff bodies, command names | `code` |

Markdown headings keep their existing relative treatment (`.title3` / `.headline` /
`.subheadline`) in both apps; they already agree and are not a step.

### Invariants

- No `.font(...)` literal in a **transcript entry renderer** outside the scale definition,
  except markdown headings. The entry renderers are `Transcript.swift`, `EntryView.swift`,
  both `BlocksView.swift`, both `MarkdownText.swift`, both `PlanView.swift`,
  `DiffView.swift`, `CommandList.swift` and `AttachmentStrip.swift`. (FR-009, FR-025)
- The scale does **not** cover the prompt bar, the document and file readers, or capsule
  and badge chrome. Those are not transcript entries and keep their own sizes.
- No `.system(size:)` on transcript entry text. Glyphs inside capsules and badges are
  exempt and must be marked as such in a comment. (FR-015)
- `App/Sources/Chat/BlocksView.swift` and `Remote/Sources/Chat/BlocksView.swift` name the
  same step for the same block kind. (FR-014)

## 3. Chat measure

```swift
// AgentsKitCore
public struct ChatMetrics: Hashable, Sendable {
    public let measure: Double
    public let padding: Double
    public static let measureCap: Double
    public static let widePadding: Double
    public static let tightPadding: Double
    public static func forPane(width: Double) -> ChatMetrics
}
```

```swift
// Shared/UI/ChatColumn.swift
extension View { func chatColumn(paneWidth: Double) -> some View }
```

### Invariants

For all pane widths `w` in the range the app can produce:

- `forPane(w).measure > forPane(w).padding * 2` — text always beats margin. (FR-019)
- `forPane(w).measure <= measureCap` — the column never runs the full width of a large
  display. (FR-017)
- `forPane(w).padding >= tightPadding` — the margin has a floor. (FR-018)
- `w1 < w2` implies `forPane(w1).measure <= forPane(w2).measure` — monotonic, so the
  column does not jump while the window is dragged. (FR-020)
- Both `Transcript` and `PromptBar` obtain their horizontal geometry from `chatColumn`,
  and neither applies a horizontal padding of its own. (FR-021)

### Behaviour

- Pane wider than `measureCap + widePadding * 2`: column sits at `measureCap`, centred,
  surplus split evenly. (FR-020)
- Pane narrower than that: padding ramps down toward `tightPadding`, text takes the rest.
  (FR-018)
- Changing pane width must not move the reader's scroll position. (FR-023)

## 4. Checks

Three assertions, in `AgentsKitTests`, reading `App/Sources` and `Remote/Sources` from disk
via `#filePath` as `MarkdownBlockTests.swift:256` already does:

1. No literal `.red`, `.orange`, `.green` or `Color.accentColor` used as a state tint
   outside `Shared/UI/StateTint.swift`. (FR-024)
2. No `.font(` literal in the transcript entry renderers listed above, outside the scale
   definition, headings excepted. (FR-025)
3. No `.padding(.horizontal, <number>)` in `Transcript.swift` or `PromptBar.swift`.
   (FR-026)

Plus ordinary unit tests on `ChatMetrics` for the four invariants above, in the manner of
`PageMetricsTests`.

## 5. What does not change

Group headings, their order, state wording, icons, and every accessibility label. (FR-027)
