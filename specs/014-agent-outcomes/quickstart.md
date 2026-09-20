# Quickstart: proving How It Actually Went works

Seven checks. The first four are the feature; the fifth is the honesty of a silence; the sixth is
compatibility; the seventh is the only one that proves a real runtime will actually do this.

## Prerequisites

```bash
swift build --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

A signed-in runtime (Claude, Copilot, Grok or Cursor) is needed for check 7 only. Checks 1–6 run
against the fake runtime in `Tests/AgentsKitTests/Fake`.

## 1. The table is total, and says the same thing everywhere

```bash
swift test --package-path Packages/AgentsKit --filter 'WorkOutcome|AgentGroup'
```

Proves SC-006 and, by construction, SC-004: every `WorkOutcome` maps to exactly one `AgentGroup` and
one heading, every `(AgentState, WorkReport?)` pair lands in exactly one group, and no view holds a
second copy of the wording. `AgentGroupTests` already walks every state; it grows to walk the product.

Also proves SC-001 negatively: no combination produces the word *Complete* without `WorkOutcome.done`.
Assert it directly — `AgentRow` and `AgentCard` should be searched for the literal `"Complete"` and
find it only behind `.done`.

## 2. An agent that needs you is findable without opening it

```bash
swift test --package-path Packages/AgentsKit --filter OutcomeReportTests
```

Covers the whole of User Story 1 and 2 against the daemon, through the real socket:

- Report `needs_answer` at the end of a turn → the agent is in `.needsAttention`, its message is on
  it, and the project's `ProjectSummary.needsInput` is true. SC-002, SC-003.
- Report `done` → `.finished`, no colour, message shown.
- Report `nothing_to_do` → `.finished`, and the line says nothing was needed rather than that work
  was done.
- Report twice in one turn → the second stands (FR-005).
- Send a prompt as the person → the report is cleared before the turn starts (FR-006).
- Report with an empty message → refused, with the sentence from `contracts/daemon-api.md`.
- Report while a permission is outstanding → refused (FR-008).
- Report on a token whose session is over → refused with `noSuchAgent` (FR-007).
- Archive an agent that reported `stuck` → it leaves Needs attention (FR-018).

## 3. A silence is asked about once, and only once

```bash
swift test --package-path Packages/AgentsKit --filter UnreportedEndingTests
```

The whole of User Story 3, and the check that makes the cost of the design bounded:

- End a turn with no report → exactly one prompt is enqueued, marked `PromptOrigin.app`.
- Let that turn end with no report either → no second prompt, ever. Count the prompts (SC-009).
- Let it end *with* a report → the agent is indistinguishable from one that reported first time.
- End a turn with no report while a person's prompt is already queued → no question at all (FR-023).
- End short — cancelled, out of room, process died → no question, and `EndedReason.summary` is what
  is shown (FR-025).
- Report, then have the process die before the turn closes → both are on the record (FR-031).
- The question's turn records usage like any other (FR-024).

## 4. The conversation and the list agree

```bash
swift test --package-path Packages/AgentsKit --filter 'TranscriptDisplay|ReplayTests'
```

A `.workReported` entry is drawn at the end of the transcript; the `report_outcome` tool call itself
is not drawn; the app's own question is drawn as a prompt that is visibly not the person's (FR-015,
FR-022).

## 5. In the app, by eye

```bash
open build/Debug/Agents.app   # or run the Agents scheme
```

Start an agent in a scratch folder and give it: *"Look at this folder, do nothing, and report the
outcome as nothing_to_do."* Then a second: *"Make a change you cannot finish and report partly_done
with a sentence about what is left."*

Confirm by eye, without opening either conversation:

- The first is under Complete, grey hollow tick, its own sentence underneath.
- The second is under Needs attention, orange, its own sentence underneath.
- The project in the sidebar carries the dot.
- Open the second: the same words are at the bottom of the conversation.

Then leave a third agent to end a turn without reporting, and watch the app ask it once — the
question appears in the conversation, attributed to Agents rather than to you.

## 6. Old records still open, new records still open in old builds

```bash
swift test --package-path Packages/AgentsKit --filter LegacyRecordTests
```

An agent record written before 014 opens with `report == nil` and `outcomeAsked == false`. A record
written by 014 and read by a decoder that does not know the fields keeps them in `unknownFields` and
writes them back. A transcript holding `.workReported` read by an older `Kind` decoder comes through
as `.unrecognised` and is skipped when drawing, not lost. An outcome string this build does not know
decodes to no report rather than throwing (FR-027).

## 7. Real runtimes actually call it

```bash
swift test --package-path Packages/AgentsKit --filter OutcomeReportLiveTests
```

The check that matters most and the only one that can fail for reasons no unit test can see. The
briefing is the whole of the lever here — `SuggestedPromptLiveTests` exists because three runtimes
called `suggest_next_prompts` exactly never until the briefing named it in words, and this feature
inherits that risk entirely.

Against each signed-in runtime, give a task with an unanswerable question in it and assert the turn
ends with a `needs_answer` report rather than with the question buried in a reply. Record the
adoption rate per runtime; SC-007 wants 90% of normally-ended turns carrying a report within a month,
and this test is where a runtime that will not play is discovered rather than guessed at.

If a runtime will not call it even with the briefing line, that is a finding, not a failure of the
design: the silent-ending path exists precisely so the app stays honest about that runtime, and
check 3 already proves it does.
