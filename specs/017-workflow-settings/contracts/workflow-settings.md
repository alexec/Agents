# Contract: Workflow settings

**Module**: `AgentsKitCore` · **File**: `Sources/AgentsKitCore/Model/WorkflowSettings.swift`

Extends [008's workflow-file contract](../../008-agentic-workflows/contracts/workflow-file.md). That
document stays true; this adds three keys to its front-matter table and nothing else about the format
changes.

## The keys

| Key | Required | Type | Meaning |
|---|---|---|---|
| `permission-mode` | no | string | The value of the runtime's own mode option, verbatim |
| `runtime` | no | string | A runtime id: `claude`, `grok`, `copilot`, `cursor` |
| `model` | no | string | The value of the runtime's own model option, verbatim |

```markdown
---
name: Morning build check
on:
  - schedule:
      at: [":00"]
      between: "09:00-09:00"
      days: [mon, tue, wed, thu, fri]
agent: new
runtime: claude
permission-mode: plan
---

Check whether the build is still green. Don't fix anything.
```

All three are optional and all three are absent from every file written before this feature. A
workflow stating none of them starts exactly as it does today: `RuntimeCatalog.builtIn[0]`, and
whatever that runtime defaults to.

The values are the runtime's own strings, passed through untouched. This app does not define a
vocabulary of modes, does not translate between runtimes, and does not assert that `plan` on one
runtime is the same promise as `plan` on another. A workflow belongs to a project, and a project's
runtime is something the person already chose.

## Surface

```swift
public struct WorkflowSettings: Codable, Hashable, Sendable {
    public var permissionMode: String?
    public var runtimeID: String?
    public var model: String?

    public var isEmpty: Bool

    /// The clause `Workflow.summary` appends: "in plan mode, on Claude". nil when empty.
    public var summary: String?

    /// What to start with, or why nothing may start.
    public enum Resolution: Sendable {
        case resolved(StartOptions)
        case refused(setting: String, value: String, offered: [String])
    }

    /// Pure. No I/O, no actor, no clock.
    public static func resolve(_ settings: WorkflowSettings,
                               against advertised: [ConfigOption]) -> Resolution

    /// The full sentence a refusal carries, given the runtime's display name.
    public static func refusalDetail(setting: String, value: String,
                                     offered: [String], runtime: String) -> String
}
```

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| S1 | Empty settings resolve to `StartOptions.none` — no key is sent, so every runtime default stands | FR-002, FR-007 |
| S2 | A named permission mode resolves to `[<mode option id>: .string(value)]`, keyed by the id the runtime advertised, not by the string `"mode"` | FR-006 |
| S3 | The mode option is found by `ModeMemory.modeOption(in:)` — by `category == "mode"` first, `id == "mode"` second | FR-023 |
| S4 | The model option is found by `category == "model"` first, `id == "model"` second | FR-006 |
| S5 | A permission mode no advertised choice matches is `.refused`, never a fallback and never omitted | **FR-008** |
| S6 | A model no advertised choice matches is `.refused` | FR-010 |
| S7 | A runtime that advertises no mode option at all, for a workflow that names one, is `.refused` with an empty `offered` | FR-008 |
| S8 | `offered` lists the choice **values**, in the order the runtime sent them, so the refusal names what would have worked | FR-012 |
| S9 | `summary` is `nil` for empty settings, and omits the runtime when it is the default | FR-027 |
| S10 | `resolve` never throws, traps, or does I/O | — |

## Where it is read

**`WorkflowFile.parse`** — three more scalars beside `name`, and `known` grows to match:

```swift
let known: Set<String> = ["on", "agent", "name", "permission-mode", "runtime", "model"]
```

A non-scalar value for any of the three is `broken(...)` — a `WorkflowProblem.unreadable`, listed and
inert, because a file whose settings cannot be read is a file somebody has to fix. A runtime id that
is not in the catalog is **not** a parse error: see [daemon-api.md](./daemon-api.md), and research §4
for why.

**`Workflow.summary`** — the clause is appended only when `mode != .triggering`:

```swift
let triggerPart = supported.map(\.summary).joined(separator: ", and ")
let base = "\(triggerPart), \(mode.summary)"
guard mode != .triggering, let settings = settings.summary else { return base }
return "\(base), \(settings)"
```

A `triggering` workflow never starts an agent, so it never applies a setting, so its row must not
claim one. This is the whole of FR-011 as far as the row is concerned; the workflow page says the
longer version.

`Workflow.summary` is read by `WorkflowRow` **and** by the reply an agent gets from
`writeWorkflowForAgent`. Extending it satisfies FR-027 and FR-029 in the same line and makes it
impossible for the page and the agent to describe the same workflow differently.

## Tests

`Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift`

| Test | Holds |
|---|---|
| `aFileWithNoSettingsStartsAsItAlwaysDid` | S1, and the whole of SC-006 |
| `aNamedModeIsSentUnderTheIdTheRuntimeAdvertised` | S2 — an option whose id is `permission_mode`, to prove nothing hard-codes `"mode"` |
| `aModeTheRuntimeDoesNotOfferIsRefusedAndNotSubstituted` | **S5 — the test that carries the feature** |
| `theRefusalNamesWhatWouldHaveWorked` | S8 |
| `aRuntimeThatOffersNoModeAtAllRefusesRatherThanIgnores` | S7 |
| `theModelIsFoundByCategoryNotByName` | S4 |
| `aTriggeringWorkflowDoesNotClaimAModeItWillNeverApply` | FR-011, via `summary` |
| `theSummaryLeavesOutTheDefaultRuntime` | S9 |
| `settingsSurviveAFileThatAlsoCarriesKeysWeDoNotKnow` | FR-004, with `unknownFields` intact |
