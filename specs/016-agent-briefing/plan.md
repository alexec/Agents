# Implementation Plan: What Every Agent Is Told

**Branch**: `016-agent-briefing` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/016-agent-briefing/spec.md`

## Summary

One new file — `Briefing`, beside `AppService`, holding one string per thing an agent is told and one
list saying which of them go and in what order — and four small changes around it: the sentence moves
out of `AppService`, the daemon's `needsSuggestionAsk` becomes `needsBriefing`, `beginTurn` appends
the block instead of the line, and a unit suite holds the ceiling.

Nothing about *when* the words are sent changes, because the existing answer is already the right
one: with the first prompt of a conversation, never again while that conversation lasts, again only
where a runtime has lost it and a new one has to be begun. That machinery exists and is tested; this
feature widens what it carries and leaves it otherwise alone.

Two lines join the one that is there. **Escalation** names no tool, because the tool belongs to the
runtime — it asks for the act and gives the reason only this app can give: the question is held by
the daemon, outlives the window, and reaches a phone. **Workflows** names `manage_workflows` exactly,
says not to write cron entries or scripts nothing will run, and carries its own restraint in the same
breath: do not create one nobody asked for.

That restraint is the one real risk here, and it is a reversal. `008/tasks.md:T065` says in as many
words: *"Do NOT add it to `askForSuggestions` or any other standing instruction — telling every agent
it can schedule things would invite exactly the behaviour the chain-depth limit exists to contain."*
That was right about the danger and wrong about the cost of silence, which turned out to be agents
writing crontabs and reporting success. The decision is revisited in [research.md](./research.md)
rather than quietly overturned.

No record grows a field, nothing is stored, no daemon API changes, and the phone is untouched. The
whole of it is about 120 lines of source and three test suites, one of which only runs against real
runtimes.

## Technical Context

**Language/Version**: Swift 6, strict concurrency.

**Primary Dependencies**: None new. `Briefing` is static strings; the call site is a `ContentBlock`
already being built.

**Storage**: None. The briefing is not persisted, not recorded, and not sent to a window. It exists
only in the prompt that carries it and in the runtime's own history afterwards.

**Testing**: `swift-testing` in `Packages/AgentsKit/Tests/AgentsKitTests`, split `Unit` /
`Integration` / `Live`. The Live suite is opt-in and is where the claims about other people's
runtimes are held, following `SuggestedPromptLiveTests` — which exists precisely because this
feature's premise was measured rather than assumed.

**Target Platform**: `agentsd` on macOS. The remote draws nothing here; an agent's briefing is not a
thing the phone has ever seen.

**Project Type**: Desktop app plus a mobile remote over a local daemon.

**Performance Goals**: None to speak of. The cost that matters is tokens, not time: one block, once
per conversation, under the ceiling in FR-019.

**Constraints**:

- The transcript must keep recording the person's words alone (FR-015). `beginTurn` already records
  before it appends, and that order is the whole of the mechanism — it must not be disturbed.
- The briefing must not be sent twice for one conversation (FR-010), including across a daemon
  restart and a `session/load` (FR-012).
- No line may name a tool the agent does not have (FR-008). Today every agent has all three; 015
  makes that false, so the shape has to survive becoming per-runtime without being rewritten.
- Deleting the call site must leave every feature still working (FR-017).
- The block must stay within a stated ceiling that fails the build when exceeded (FR-019).

**Scale/Scope**: One new source file, three edited, one new unit suite, one new live suite, one
integration suite extended. Around 120 lines of source.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unedited template — every principle is a
`[PRINCIPLE_N_NAME]` placeholder — so there are no ratified gates, and none are invented here. In
their place, the conventions this codebase holds itself to, read off the existing sources, and how
this design stands against each:

| Standing convention | How this design stands |
|---|---|
| No code asks which runtime it is talking to (README; `RuntimeDiscovery`) | Every agent gets the same block. The runtime is never consulted. 015 changes this on purpose and this design leaves it the seam to do so. |
| An agent is told, in a sentence, what happened to anything it asked for (`AppService.Outcome`) | Unchanged. The briefing adds no new reply path; it points at tools that already answer this way. |
| The transcript records what the person said, not what we added (`beginTurn`) | Preserved exactly: recorded before the block is appended, and the block is its own `ContentBlock`. |
| A claim about somebody else's software gets a check that can be re-run (`scripts/acp-handshake.sh`, `SuggestedPromptLiveTests`) | SC-001 and SC-002 are claims about four runtimes' behaviour, and `BriefingLiveTests` is where they are re-taken. |
| Words are the weakest lever and are used last (015) | Acknowledged and bounded: the ceiling exists so that words cannot quietly become the answer to everything. |
| Comments say why, at length, and name what would go wrong otherwise | The reversal of `008/T065` is written into the file that does it, not only into this plan. |

**Post-design re-check**: passes unchanged. The design adds no new daemon API, no stored state, no
runtime branching, and no new place for the app's words to end up in the person's record.

## Project Structure

### Documentation (this feature)

```text
specs/016-agent-briefing/
├── plan.md              # This file
├── research.md          # Phase 0: the five decisions, including the T065 reversal
├── data-model.md        # Phase 1: Briefing, Line, and the flag that decides
├── quickstart.md        # Phase 1: how to see it work, fake and live
├── contracts/
│   └── briefing.md      # Phase 1: the exact words, the order, the ceiling, the seams
├── checklists/
│   └── requirements.md  # From /speckit-specify
└── tasks.md             # Not created by /speckit-plan
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/
│   ├── Briefing.swift               # NEW. suggestions, escalation, workflows; lines; text
│   └── AppService.swift             # askForSuggestions leaves; the workflow tool's
│                                    #   "gets no instruction" comment is corrected
└── Daemon/
    ├── DaemonCore.swift             # needsSuggestionAsk → needsBriefing
    └── DaemonCore+Commands.swift    # appends Briefing.text; three insert sites renamed

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/BriefingTests.swift         # NEW. every line present, tools named, ceiling held
├── Integration/SuggestedPromptTests.swift
│                                    # existing once / again-when-lost / not-in-transcript
│                                    #   tests move from the sentence to the block
└── Live/BriefingLiveTests.swift     # NEW. SC-001 and SC-002 against real runtimes
```

**Structure Decision**: `Briefing` goes in `AgentsKit/ACP/Serve/`, beside `AppService`, and not in
`AgentsKitCore`. The rule the two modules divide on is whether the phone needs it: `AppTool` is in
Core because a phone reading a transcript has to tell the app's tool calls from the agent's work, and
the briefing is never drawn anywhere, by anything. It is sent by the daemon and read by a model.

It is its own file rather than more of `AppService` because the two answer different questions —
`AppService` is what an agent *may* do, `Briefing` is what it is *told to* do — and because 014 and
015 both already plan to edit the second without touching the first.

## Complexity Tracking

No Constitution Check violations. One decision is worth recording as deliberate rather than as
complexity: `Briefing.lines` is a computed list rather than three strings concatenated at their use
site, which is marginally more machinery than today's single constant needs. It is what makes FR-018
and FR-020 true — 014's line joins by adding one entry — and it is what the ceiling test iterates.

## Dependency note

`014-agent-outcomes` and `015-runtime-tool-scoping` were both planned against this file existing.
`014/tasks.md:T032` adds `Briefing.outcome` to `lines`; `015/tasks.md:T041–T044` turn `Briefing.text`
into `Briefing.text(for:)` and shrink the workflows line per runtime. Both quote this feature's
comments and its 1,200-character ceiling. This plan therefore fixes the names they use —
`Briefing.swift`, `suggestions`, `escalation`, `workflows`, `lines`, `text`,
`BriefingTests.itStaysShortEnoughToBeRead` — and treats them as a contract rather than as taste.
Building this first makes both of those plans executable as written.
