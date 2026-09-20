# Contract: what a person sees

The wording lives on `WorkOutcome`, not here and not in any view. This page is what that wording
renders to, on both platforms, so that FR-017 is checkable by reading one table.

## The agents panel

```text
┌──────────────────────────────────────────────┐
│ Needs attention                              │
│  ? Fix the parser                        ●   │  needsAnswer — orange, filled
│    Drop the old index first, or migrate it?  │  ← the agent's message, not ours
│  ◐ Update the call sites                 ●   │  partlyDone — orange
│    Five of six done; the sixth is generated  │
│  ! Ship the release                      ●   │  stuck — orange
│    No signing certificate on this machine    │
│                                              │
│ Working                                      │
│  ◌ Write the migration                       │
│                                              │
│ Complete                                     │
│  ✓ Rename the module                         │  done — green, filled
│    Renamed 14 call sites; tests pass         │
│  ✓ Nightly build check                       │  nothingToDo — grey, hollow
│    Nothing failed overnight                  │
│  ? Tidy the imports                          │  unaccounted — grey, hollow
│    Finished without saying how it went       │  ← ours, because nobody said
│                                              │
│ Stopped                                      │
│  ■ Long refactor                             │
│    Ran out of room                           │  ← EndedReason.summary, unchanged
└──────────────────────────────────────────────┘
```

Same in `App/Sources/AgentList/AgentRow.swift` and `Remote/Sources/Projects/AgentCard.swift`.

## The three view sites, and what each reads

`AgentRow.description` and `AgentCard`'s equivalent gain one branch, placed by precedence:

1. `isComingBack` — unchanged, still wins over everything.
2. `agent.currentStep` — unchanged, and only ever set while a plan is in progress, so it cannot
   collide with a settled report.
3. **`agent.report?.message`** — new. The agent's own words (FR-013).
4. **unaccounted-for ending** → `"Finished without saying how it went"` (FR-019).
5. the existing `switch agent.state`, unchanged.

`StatusIcon` takes the report alongside the state, and resolves as Research R3 sets out:

| Shown | Symbol | Tint | Accessibility label |
|---|---|---|---|
| `done` | `checkmark.circle.fill` | green | Complete |
| `nothingToDo` | `checkmark.circle` | secondary | Nothing to do |
| `needsAnswer` | `questionmark.circle.fill` | orange | Waiting on your answer |
| `partlyDone` | `circle.lefthalf.filled` | orange | Partly done |
| `stuck` | `exclamationmark.triangle.fill` | orange | Stuck |
| finished, unaccounted for | `questionmark.circle` | secondary | Finished without saying how it went |
| every other state | unchanged | unchanged | unchanged |

Filled means somebody said so; hollow means nobody did; orange means you.

## The conversation

The report is drawn as the last thing in the transcript, by `App/Sources/Chat/Transcript.swift` and
`Remote/Sources/Chat/EntryView.swift`, from the `.workReported` entry — so the list and the
transcript agree about the same turn (FR-015). It reads as the outcome's `heading` above the agent's
message, in the manner of the existing state-change lines rather than as a message from the agent.

The `report_outcome` tool call itself is suppressed in `TranscriptEntry.display`, exactly as
`suggest_next_prompts` is and for the same reason.

The app's own question after a silent ending is drawn as a prompt, because it is one, but visibly
not the person's: `PromptOrigin.app` on the entry, drawn in the transcript's secondary voice with a
short attribution ("Agents asked"), never in the person's bubble (FR-022).

## The project page

- The sidebar's dot follows `ProjectSummary.needsInput`, which follows `counts[.needsAttention]`,
  which now counts reported outcomes. No change to that code (FR-016).
- A workflow's row, in `App/Sources/Projects/WorkflowRow.swift`, adds the outcome of the agent its
  last run started: `WorkflowOutcome.ran` already carries the `agentID`, so the row looks the agent up
  and shows its report's message under the existing "Ran" line (FR-028, FR-033). A run whose agent
  reported something needing a person earns the same colour the row already gives a refusal that
  needs one (FR-029, FR-034).

## What does not change

- "Needs attention", "Working", "Complete", "Stopped", "Archived" keep their headings. An outcome
  moves an agent between them; it does not rename them.
- `EndedReason.summary` keeps every word. A turn that ended short still reads exactly as it does
  today, and where both exist the ending is shown with the report beneath it (FR-030, FR-031).
- Nothing about permissions, elicitation or `show_file` changes on screen.
