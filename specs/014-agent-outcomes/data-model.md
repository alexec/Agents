# Data Model: How It Actually Went

## `WorkOutcome`

`Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift` — new.

A closed enum of five, `String`-backed, `Codable`, `CaseIterable`. It carries its own wording and its
own grouping, for the reason `EndedReason.summary` gives: the phone and the window have to say the
same words about the same agent, and two copies of a switch are two chances to drift.

```swift
public enum WorkOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    case done, nothingToDo, needsAnswer, partlyDone, stuck
}
```

| Case | Wire | Means | `needsAPerson` | `heading` |
|---|---|---|---|---|
| `done` | `done` | Asked for, and done | `false` | Complete |
| `nothingToDo` | `nothing_to_do` | Looked, and there was nothing to do | `false` | Nothing to do |
| `needsAnswer` | `needs_answer` | Cannot go further until a person answers | `true` | Waiting on your answer |
| `partlyDone` | `partly_done` | Some of it done, the rest needs a decision | `true` | Partly done |
| `stuck` | `stuck` | Could not do it, and says why | `true` | Stuck |

**Members**

- `needsAPerson: Bool` — the whole of the grouping rule, and the predicate 005's unbuilt notifier
  will read. Named after `WorkflowRefusal.needsAPerson`, which answers the same question about a
  workflow and earns colour on the same page.
- `heading: String` — what the app says when it has to speak for itself: the icon's accessibility
  label, the tooltip, and the transcript's label above the agent's own sentence. Never shown in place
  of the message on a row — the message wins there (FR-013).
- `init?(wire:)` — an unrecognised string returns `nil`, and the caller treats that as a report that
  never arrived (FR-027). Not rounded to a known case.

## `WorkReport`

Same file. The outcome, the words, and when.

```swift
public struct WorkReport: Codable, Hashable, Sendable {
    public var outcome: WorkOutcome
    public var message: String     // required, trimmed, cut to 1_000
    public var at: Date
}
```

**Validation** (FR-003, R9): the message is trimmed of whitespace; empty after trimming is refused,
not stored. Longer than `WorkReport.messageLimit` (1,000) is cut, not refused.

**Lifecycle**

| Event | What happens to the report |
|---|---|
| Agent reports | Replaces whatever was there (FR-005) |
| Turn ends | Nothing. The report stands as the account of that turn |
| Person's prompt enqueued | Cleared (FR-006), as `suggestedPrompts` is |
| The app's own question enqueued | **Not** cleared — there is nothing there to clear, and clearing is how a person's prompt is told apart from the app's |
| Agent archived | Kept. Archiving changes the group, not the record (FR-018) |

## `Agent` — two new fields

`Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`.

```swift
/// What the agent said about how the work went, from the turn that just ended.
public var report: WorkReport?

/// Whether this agent has already been asked to account for an ending it did not
/// account for. Set when the question is enqueued, cleared by a prompt from the
/// person. One ask per silence, and the agent cannot write it.
public var outcomeAsked: Bool
```

Both decode with `decodeIfPresent` — `report` to `nil`, `outcomeAsked` to `false` — so every record
written before 014 opens as an agent that never reported and has never been asked.

**Derived**

```swift
/// Whether somebody has to do something about this agent.
var needsAPerson: Bool   // state == .waitingOnUser, or a settled report that needs one
/// A turn that ended cleanly and was never accounted for (FR-019).
var endingIsUnaccountedFor: Bool  // .finished, endedReason == .endTurn, report == nil, asked already
```

## `AgentGroup` — one more argument

```swift
public init(for state: AgentState, wantsEyes: Bool = false, report: WorkReport? = nil)
```

Still total over `(AgentState, Bool, WorkReport?)`. The added rule is one line: a `.finished` agent
whose report needs a person is `.needsAttention`. Everything else is unchanged — in particular
`.stopped` and `.archived` ignore the report entirely, because how a turn *ended* outranks what the
agent said about the work (FR-030, FR-018).

| State | Report | Group |
|---|---|---|
| `waitingOnUser` | any | `needsAttention` |
| `running` | any | `running`, or `needsAttention` with `wantsEyes` |
| `finished` | needs a person | **`needsAttention`** |
| `finished` | does not, or none | `finished`, or `needsAttention` with `wantsEyes` |
| `stopped` | any | `stopped` |
| `archived` | any | `archived` |

## `TranscriptEntry.Kind` — one new case

```swift
case workReported(WorkReport)
```

Coded by hand in `TranscriptEntry+Coding.swift` under the key `workReported`, both directions. An
older build reads it as `.unrecognised` and skips it when drawing, which is what that case is for.

## `TranscriptEntry.Kind.userMessage` — an origin

```swift
public enum PromptOrigin: String, Codable, Hashable, Sendable {
    case person
    /// The app asking on its own behalf. Today: the one question after a silent ending.
    case app
}

case userMessage(String, blocks: [ContentBlock] = [], from: PromptOrigin = .person)
```

Added as a key on the existing case rather than a new case, for the reasons in Research R5. Absent on
the wire means `.person`, so every record ever written stays correct. `QueuedPrompt` and
`DaemonAPI.PromptRequest` carry the same field, defaulted the same way, so a remote that has not been
rebuilt still sends prompts that are the person's.

## `AppTool`

```swift
/// And the fourth: how the work went, said at the end of it.
public static let reportOutcome = "report_outcome"
```

## `DaemonAPI`

```swift
public static let agentsReportOutcome = "agents/reportOutcome"

public struct ReportOutcomeRequest: Codable, Sendable {
    public var token: String       // the session's, as the other app tools use
    public var outcome: String     // the wire spelling; unknown is refused at the door
    public var message: String
}
```

No new `Failure` code. See contracts/daemon-api.md for which existing ones are raised.

## What is deliberately not modelled

- **No new `AgentState`.** Research R2.
- **No expiry on a report.** A question nobody answered is still a question (spec edge case).
- **No history of reports.** One per turn, replaced in place. The transcript holds the sequence, and
  that is what a record is for.
- **No copy of the report on `WorkflowOutcome`.** Research R10.
