# Data Model: One Call to End a Turn

Nothing stored changes. `Agent.report` (`WorkReport?`) and `Agent.suggestedPrompts`
(`[SuggestedPrompt]`) are exactly as 014 and the suggestion feature left them, cleared by the same
`clearSuggestions` and report-clearing on the next prompt. A record written by this build opens in
an older one and the reverse.

What changes is on the wire.

## `AppTool.finishTurn`

`Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift`

```swift
public static let finishTurn = "finish_turn"
/// Older names for the two halves of `finishTurn`, kept so a conversation briefed with
/// them before 2026-09-23 still finds what it was told. Remove together, once no such
/// conversation could be resumed.
public static let suggestPrompts = "suggest_next_prompts"
public static let reportOutcome = "report_outcome"
```

## `DaemonAPI.FinishTurnRequest`

`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`

| Field | Type | Notes |
|---|---|---|
| `token` | `String` | The session's app token, as every app tool request carries. |
| `outcome` | `String` | Wire spelling. Checked at the daemon as `ReportOutcomeRequest.outcome` is; never rounded. |
| `message` | `String` | Trimmed at the service. Empty refused at both ends. |
| `prompts` | `[SuggestedPrompt]` | The MCP argument is `next_prompts`; the service cleans it with `SuggestedPrompt.list(in:)` and cuts it to `SuggestedPrompt.limit`. Empty means no chips. |

`DaemonAPI.Method.agentsFinishTurn = "agents/finishTurn"`.

## `AppService.FinishSink`

```swift
public typealias FinishSink =
    @Sendable (_ outcome: String, _ message: String, _ prompts: [SuggestedPrompt]) async -> Outcome
```

A fifth sink beside the four, defaulted to a refusal like the others so a test that does not wire
it still gets a sentence.

## `PermissionRequest.isFinishingTurn`

```swift
public var isFinishingTurn: Bool { (name ?? title).hasSuffix(AppTool.finishTurn) }
public var isTheApps: Bool {
    isFinishingTurn || isSuggestingPrompts || isShowingFile || isManagingWorkflows || isReportingOutcome
}
```

## Validation, in the order it runs

At `AppService.handle`, before the sink:

1. `outcome` trimmed; must be one of the five (`WorkOutcome(wire:)` non-nil) → else refused naming
   the five.
2. `message` trimmed; must be non-empty → else refused with the outcome tool's sentence.
3. `prompts` → `SuggestedPrompt.list(in:)`: trimmed, cut to four, empties dropped, missing → `[]`.

At `DaemonCore.finishTurn`, before any write:

4. Token binds to a live agent → else `noSuchAgent`.
5. Outcome parses → else `invalidParams` (belt and braces, as `reportOutcome` does).
6. No pending permission or elicitation for the agent → else `invalidParams` with 014's sentence.
7. `WorkReport(outcome:wire:)` non-nil → else `invalidParams`.

Then, in this order: `agent.report = report`; `agent.suggestedPrompts = prompts`;
`record(.workReported(report), for:)`; `changed(agent)` once; `reconsider()`.

## State

No new state and no new transition. The one call sets two fields the turn already owns and clears
nothing the next prompt would not clear anyway.
