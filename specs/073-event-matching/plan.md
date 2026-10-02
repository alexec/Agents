# Implementation Plan: Finer event matching, step 1

**Branch**: `agents/build-spec-073-finer` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/073-event-matching/spec.md` (#99, step 1), and the
research it follows, [`specs/research/099-event-matching.md`](../research/099-event-matching.md),
with Alex's four decisions taken as recommended there.

## Summary

A filter stops being one string and becomes `DetailFilter`: one value or a list meaning "any of".
`EventPattern.matches` stays the one matcher for triggers and waits. It asks the catalogue
whether a detail is a **set** (`labels`), and compares a set detail by label key.

The catalogue's `details: [String]` becomes `[EventDetail]`. Each entry has its key, whether it is
a set, its fixed values (or none, for open details), the old sentence words that map to each
code, and its phrase for the summary. `EventPattern.parse` uses it to:
- check values, refusing with one sentence that lists the valid values;
- map old words to codes;
- refuse old words that map to no code.

The daemon adds agent context (`labels`, `runtime`, `started_by`) in `agentDetails`, and
`afterwards` on `agent.finished`. It adds `outcome` to `workflow.completed`, `agent.parked` and
`agent.archived`. It raises codes instead of sentences for `agent.failed reason`,
`agent.stopped by`, `agent.archived by` and `workflow.refused reason`. Each event's sentence keeps
today's words.

The three readers stop dropping lists: the workflow file, the wait tool's `where`, and the wire.
The words follow: `summary`, `label`, `asTrigger`, Copy as trigger, the Mac Triggers capsules, and
the web page's trigger words. The Remote reads `Workflow.summary` from AgentsKitCore, so it
follows with no change of its own.

**Order of work.** The order is the one asked for. First the matcher, the catalogue and their
words, with unit tests. Then the readers and the daemon's details. Then the page, the web page and
Copy as trigger. Docs come last.

## Technical Context

**Language/Version**: Swift 6.2 with strict concurrency (AgentsKit, the Mac app); TypeScript 5.x
`strict` for `Web/`.

**Primary Dependencies**: none new.

**Storage**: `EventPattern` is saved inside `EventWait` (on agent records) and inside
`WorkflowCause` (in the workflow store). Event details stay `[String: String]`. `labels` is
comma-joined: labels can't contain commas.

**Testing**: `swift test --package-path Packages/AgentsKit` (Swift Testing), `npm test` in
`Web/` (node --test), and a run-app scratch root driven over `daemon.sock`.

**Target Platform**: macOS host (agentsd), the Mac window, iOS Remote, the web page.

**Project Type**: multi-app Swift repo with a shared core package.

**Performance Goals**: matching stays O(filters) per event. The catalogue lookup is a
dictionary.

**Constraints**:
- FR-028: patterns with only single values encode byte for byte as today.
- FR-029: a list must not make a record unreadable to the previous version.
- The web page ships with the host. Phones may be older.

**Scale/Scope**:
- about 10 Swift files in AgentsKitCore and AgentsKit, and 1 in the Mac app;
- 2 web files and one generated-types override;
- 5 docs pages.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec 073 with acceptance scenarios; this plan, then tasks, then implement. |
| II. Capability-driven runtimes | Untouched: `runtime` is a detail value, not a behaviour switch. |
| III. Scoped access | Scope is unchanged (decision 4): a project's events still reach only its own workflows and waits. |
| IV. Inspectable | A filter is never dropped silently (SC-002). Every refusal names what would have been right (SC-004). The Events page keeps today's sentences. |
| V. Docs and quality | The five docs pages in the spec's Docs section change with the code. `generated.ts` and `Web/dist` are regenerated and checked by `scripts/web.sh check`. |

No violations. Gate passes before and after design.

## Project Structure

### Documentation (this feature)

```text
specs/073-event-matching/
├── spec.md
├── plan.md          # this file
├── research.md      # decisions taken while planning (R1–R8)
├── data-model.md    # DetailFilter, EventDetail, EventPattern encoding
├── contracts/
│   ├── patterns.md  # file, wait and wire forms; problem sentences
│   └── catalogue.md # every detail's values, words and old-word mapping
├── quickstart.md    # how to prove it, unit and scratch root
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/Model/
├── DetailFilter.swift           # new: one value or any of; matches(detail:set:)
├── EventDetail.swift           # new: a catalogue detail: key, set, values, old words, phrase
├── EventCatalogue.swift        # details become [EventDetail]; describe() lists values
├── EventPattern.swift          # filters: [String: DetailFilter]; parse checks values; words
├── WorkflowTrigger.swift       # wire decode/encode keeps lists
├── WorkflowTriggerWords.swift  # filters for the capsules
├── EndedReason.swift           # `code`
└── WorkflowOutcome.swift       # WorkflowRefusal.code
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Events.swift  # where: [String: DetailFilter]
Packages/AgentsKit/Sources/AgentsKit/
├── Workflows/WorkflowFile.swift            # lists under a detail
├── ACP/Serve/AppService.swift              # where: lists, refuse anything else
└── Daemon/
    ├── DaemonCore+Events.swift             # codes, afterwards
    ├── DaemonCore+EventWaits.swift         # agentDetails: labels, runtime, started_by
    ├── DaemonCore.swift                    # afterwards, outcome on parked/archived, by codes
    └── DaemonCore+Workflows.swift          # workflow.refused code, workflow.completed outcome
App/Sources/Projects/WorkflowPage.swift     # capsules: "outcome: done | nothing_to_do"
Packages/WebTypes/Overrides/EventPattern.ts # the hand-written encoding, for generated.ts
Web/src/model/workflows.ts                  # trigger words and capsules, lists included
Web/test/…                                  # the web words' tests
docs/reference/events.md, docs/reference/workflows.md, docs/how-to/wait-for-something.md,
docs/how-to/set-up-a-workflow.md, docs/reference/agent-tools.md
```

**Structure Decision**: Everything that decides is in AgentsKitCore, so the daemon, the Mac and
the phone share one matcher and one set of words. The web page ports the words by hand, as it
already does for the rest of a workflow's row.

## Complexity Tracking

None.
