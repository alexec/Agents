# Implementation Plan: What Survives a Restart

**Branch**: `025-surviving-a-restart` | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/025-surviving-a-restart/spec.md`

## Summary

Four facts the app already has are written down at the moment it has them, so the next
daemon knows them too: which needs have been delivered and when each was first raised;
which workflow runs are in flight; that a question ended without an answer; and what the
person had half-typed.

Nothing new is detected, decided or shown. Every one of these is an existing in-memory
dictionary given a file, or an existing transcript path given a sentence. The whole of the
work is three small stores, one constant, and the ordering care that makes loading them
happen at the right moment.

## Technical Context

**Language/Version**: Swift 6, strict concurrency

**Primary Dependencies**: none added. Foundation, SwiftUI, Swift Testing — all already here

**Storage**: JSON files under the daemon's root, written whole and atomically, exactly as
`projects.json`, `workflows.json` and `devices.json` already are. Plus `UserDefaults` for
the window's drafts, where the window already keeps what it knows

**Testing**: `swift test --package-path Packages/AgentsKit`. The package is the only test
target wired into the schemes, which is why the draft model goes in `AgentsKitCore` rather
than in `App/Sources`

**Target Platform**: macOS. The iOS app is untouched — see research §12

**Project Type**: desktop app plus a helper daemon, one shared package

**Performance Goals**: no new work in any hot path. `reconsider()` runs on every presence
report and every state change, so its write happens only when the content moved

**Constraints**: nothing may depend on a tidy shutdown — `agentsd` has no signal handler
and can be killed outright, so every fact is written at the moment it becomes true. No
file here may cost an agent, a transcript or a project when it cannot be read

**Scale/Scope**: a handful of outstanding needs, a handful of runs, tens of drafts, for one
person

## Constitution Check

`.specify/memory/constitution.md` is the unfilled template — no project principles are
recorded, so there are no gates to evaluate and none to violate. The standards this
feature is actually held to are the repository's own, and they are the ones that shaped
the design above:

| Repository rule | How this feature meets it |
|---|---|
| The daemon is the only writer of its root | Both new stores are the daemon's. Drafts are in `UserDefaults`, deliberately not in that directory |
| One definition of a thing, never two | `Need` stays derived. No stored copy of what a need says |
| A record that cannot be read costs that record, never the app | Every load falls back to empty and the daemon starts |
| Write first, tell the windows after | Unchanged, and extended: the notes are written before the withdrawal goes out |
| An older build must still read what a newer one wrote | A `runtimeNote` rather than a new transcript kind; `runs` is additive to a file that is already read leniently |

## Project Structure

### Documentation (this feature)

```text
specs/025-surviving-a-restart/
├── plan.md              # This file
├── spec.md
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── stored-files.md
│   └── transcript-line.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not created here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Attention/
│   └── Delivery.swift                 # + Codable
├── Model/
│   ├── Draft.swift                    # NEW — Draft, StartDraft, DraftKey
│   └── RuntimeNote.swift              # + the unanswered-question wording
└── Store/
    └── DraftStore.swift               # NEW — UserDefaults-backed, injectable

Packages/AgentsKit/Sources/AgentsKit/
├── Store/
│   ├── AttentionStore.swift           # NEW — attention.json
│   ├── StoreLocations.swift           # + attention
│   └── WorkflowStore.swift            # + runs on WorkflowRecords
└── Daemon/
    ├── Daemon.swift                   # + load the runs before recover()
    ├── DaemonCore.swift               # + the store, + a question's closing line
    ├── DaemonCore+Attention.swift     # + load, write-when-moved, pending withdrawals
    ├── DaemonCore+Commands.swift      # + a closing line when the person stops an agent
    ├── DaemonCore+Recovery.swift      # + a closing line for an agent found waiting
    └── DaemonCore+Workflows.swift     # + persist, load and prune runs

App/Sources/
├── AppModel.swift                     # draft fields read from and written to the store
└── Chat/PromptBar.swift               # restore on appear, save as typing settles, clear on send

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/
│   ├── AttentionStoreTests.swift      # NEW
│   ├── DraftStoreTests.swift          # NEW
│   └── WorkflowRunStoreTests.swift    # NEW
└── Integration/
    ├── AttentionTests.swift           # + across a restart
    ├── UnansweredQuestionTests.swift  # NEW — the three ways a question dies
    └── WorkflowFiringTests.swift      # + a chain across a restart
```

**Structure Decision**: the existing layout, unchanged. Daemon-side stores go beside the
four that are already in `AgentsKit/Store`; anything the app needs to share or to have
tested goes in `AgentsKitCore`, which is the only place a test can reach it.

## Phasing

The five stories are independent and ship in priority order. Each is a working change on
its own.

| Phase | Story | What it delivers |
|---|---|---|
| 1 | US1 | `attention.json`, deliveries and raised-at persisted and loaded. The phone stops being buzzed twice |
| 2 | US2 | Withdrawals for needs that died, and the pending-withdrawal retry that makes them arrive |
| 3 | US3 | `runs` in `workflows.json`, loaded before recovery, pruned after. Chains and the depth ceiling survive |
| 4 | US4 | The closing line, on all three paths a question can die |
| 5 | US5 | Drafts in `UserDefaults`, restored, swept and cleared on send |

Phase 2 depends on Phase 1 — there is nothing to withdraw until the deliveries are on
disk. Phases 3, 4 and 5 depend on nothing and could be done in any order.

## The three places this is easy to get wrong

Collected here because they are the whole of the risk, and each is a one-line mistake with
a silent consequence.

1. **The runs must be loaded before `recover()`, not in `startWorkflows()`.** Recovery
   defers its lifecycle events with the depth computed at that moment. Load the runs after
   and every deferred event is depth zero — the ceiling this feature claims to save,
   silently lost. (research §7)

2. **A withdrawal decided at start-up has nowhere to go yet.** It leaves as a `mailbox/post`
   broadcast for the bridge to carry, `broadcast` does nothing when no broadcaster is set,
   and the bridge reconnects on a five-second loop. Post it once at start-up and it is
   very likely lost — and unlike every other post there is no next decision to repeat it,
   because the need is gone forever. Hence the pending-withdrawal list. (research §5)

3. **The closing line must not be a passing note.** `RuntimeNote.isPassing` names notes the
   chat drops once superseded. Add this one to that set and it disappears the moment the
   ending line follows it, which is always. (contracts/transcript-line.md)

## Complexity Tracking

No constitution gates to violate. One piece of this feature is more machinery than its
story looks like it needs, and it is called out rather than smuggled in:

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| `withdrawing`, the pending-withdrawal list | A withdrawal decided at start-up is shouted into an empty room, and the need it is about no longer exists to prompt a second attempt | Posting once and relying on the device's sweep leaves a wrong banner on any phone that does not connect — which is the failure US2 exists to fix |
| The draft types in `AgentsKitCore` rather than `App/Sources` | The package's tests are the only ones the schemes run; in the app target this logic is covered by nothing | Keeping it beside `SidebarFrame` matches the neighbours but is untestable, and the pruning and capping rules are exactly the parts worth testing |
