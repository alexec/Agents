# Phase 1: Data Model

One new type, one new field on two existing ones, one new refusal case. Nothing is stored anywhere
new.

---

## `WorkflowSettings`

**Module**: `AgentsKitCore` · **File**: `Sources/AgentsKitCore/Model/WorkflowSettings.swift`

What a workflow says about how its agent should be started.

| Field | Type | Meaning | Absent means |
|---|---|---|---|
| `permissionMode` | `String?` | The runtime's own value for its mode option, verbatim | The runtime's default |
| `runtimeID` | `String?` | A `RuntimeCatalog` id | `RuntimeCatalog.builtIn[0].id`, which is what happens today |
| `model` | `String?` | The runtime's own value for its model option, verbatim | The runtime's default |

Derived:

- `isEmpty: Bool` — all three absent. A workflow with empty settings takes the current start path
  untouched, which is how FR-002 and SC-006 are kept true.
- `summary: String?` — the clause `Workflow.summary` appends, e.g. `in plan mode, on Claude`.
  `nil` when empty. Omits the runtime when it is the default, because naming the default on every
  row is noise.

Codable, Hashable, Sendable. It travels to a window inside `Workflow`, which is why it is in Core.

### Validation

Validation happens in two places, and which one catches a problem decides what the reader is told.

| Problem | Caught by | Becomes |
|---|---|---|
| A value that is not a scalar (`permission-mode:` with a list under it) | `WorkflowFile.parse` | `WorkflowProblem.unreadable` — the file is wrong, somebody has to fix it |
| A runtime id not in the catalog | The start path | `WorkflowRefusal.settingRefused` — the file may be fine and the world moved |
| A mode or model the runtime does not advertise | The start path, against the live session | `WorkflowRefusal.settingRefused` |
| A key this version does not know | `WorkflowFile.parse` | Kept in `unknownFields`, as today. Not a problem at all |

The second row is the one worth defending. A runtime dropped from the catalog, or renamed, should
not turn every file naming it into a broken file on the project page — it should turn into a
workflow that says why it did not run, which is a thing the reader can act on with the file in front
of them.

### Resolution

```swift
public enum Resolution: Sendable {
    /// What to start with. Empty values are a legitimate answer.
    case resolved(StartOptions)
    /// Nothing may start. The sentence is the refusal's own words.
    case refused(setting: String, value: String, offered: [String])
}

public static func resolve(_ settings: WorkflowSettings,
                           against advertised: [ConfigOption]) -> Resolution
```

Pure. No I/O, no actor, no clock — the same rule `Workflow.refusalIfBlocked` and `ModeMemory` follow,
and for the same reason: a decision that can be wrong in a way a person would notice belongs
somewhere `swift test` can reach without a daemon.

Rules, in order:

1. `permissionMode` — find the option with `ModeMemory.modeOption(in:)`. No such option, or no
   choice whose `value` equals the named one, is `.refused` with `offered` listing the values that
   exist. Never a fallback.
2. `model` — find the option by `category == "model"`, falling back to `id == "model"`. Same rule.
3. Absent settings contribute nothing to `StartOptions.values`, so the runtime's own defaults stand.

`runtimeID` is not resolved here: it decides which session to make, so it is checked against
`RuntimeCatalog` before there is anything to resolve against.

---

## `Workflow.settings`

`Workflow` gains `public var settings: WorkflowSettings`, defaulting to empty. Two consequences:

- **`Workflow.summary`** appends `settings.summary` — but only when `mode != .triggering`. A
  `triggering` workflow never starts an agent, so a row claiming it runs in plan mode would be a
  false statement in the one place this feature exists to make true (see research §5).
- **`unknownFields`** loses three keys: `known` in `WorkflowFile.parse` grows from
  `["on", "agent", "name"]` to include the three. Anything else a later version writes still lands
  in `unknownFields` and still survives being written back.

`WorkflowSummary` needs no field: it already carries the whole `Workflow`.

---

## `WorkflowRefusal.settingRefused`

```swift
case settingRefused(setting: String, detail: String)
```

- `message` → `detail`, which is a full sentence written where the refusal is made, e.g.
  `"plan" is not a permission mode Claude offers here — it offers default, acceptEdits, bypassPermissions`.
- `needsAPerson` → **`true`**. This one does not resolve itself. It will refuse every fire until
  somebody changes the file or the runtime changes back, which is the same test `overLimit` and
  `unreadable` already pass.
- `isSameReason(as:)` → compares `setting` only, not `detail`. Three identical refusals over a
  weekend are one thing that keeps happening, collapsed by `WorkflowOutcome.following` into one row
  with a count — the rule `chainTooDeep` already follows by ignoring its depth.

Nothing else in `refusalIfBlocked` changes. That function is pure and knows nothing about runtimes;
a setting refusal is raised in the start path, where the advertised options are, and recorded through
the same `record(.refused(...))` call every other late refusal uses.

---

## What deliberately does not change

| Thing | Why it stays put |
|---|---|
| `WorkflowState` / `WorkflowRecords` | Settings are in the repository. The app's records hold only what cannot be — archived, standing agent, last outcome. |
| `StartOptions` | Already `[String: JSONValue]` keyed by advertised option id. The resolver produces one; nothing about the type needs to know where it came from. |
| `ACPSession.apply` | Left lenient, for the person. See research §2. |
| `Agent` | An agent started by a workflow already records `startedByWorkflow`, and its `startOptions` already record what it was started with. Both answer "what did this run actually use". |
| `Remote/` | Has never drawn a workflow. |
