# Implementation Plan: Park a Chat to Come Back To Later

**Branch**: `040-parked-chats` | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/040-parked-chats/spec.md`

## Summary

Parking is one new fact on the agent record, one new group, and two new daemon methods. It is not
a state and not an ending, so nothing in the transition table changes.

1. **`Agent.parking`**, an optional enum kept by the daemon on the record: `whenTurnEnds(since:)`
   or `parked(at:)`. Absent means not parked. It sits beside `endedReason` and `report` and never
   replaces either, so unparking puts the chat back exactly where its ending says (FR-002, FR-008).
2. **`AgentGroup.parked`**, added to `AgentGroup.live` after `.stopped`. `AgentGroup(for:…)` gains a
   `parked:` argument with no default, so the compiler lists every caller, as it did for
   `wantsEyes`. Only `.parked(at:)` moves a chat into the group. A question asked mid-turn
   (`waitingOnUser`) and `archived` both outrank it. The Mac and the phone already draw
   `AgentGroup.live` in a loop, so the heading appears on both in the right place with no layout
   code of its own (FR-003, FR-013).
3. **`Agent.parkAction`** in AgentsKitCore: `.park`, `.unpark` or nil. It is the one place that
   decides which button a chat shows, and every device reads it (FR-012).
4. **Two daemon methods, `agents/park` and `agents/unpark`**, on `DaemonCore`. Park on a chat with
   a turn in flight (`starting`, `running`, `waitingOnUser`) writes `whenTurnEnds`. Park on a settled
   chat writes `parked`. Both are no-ops when already in that state (FR-017). Neither touches the
   runtime, the transcript or the queue (FR-005).
5. **Promotion at the turn's end** is added in `DaemonCore.move`, the one place every state change
   passes through. When the next state is `finished` or `stopped` and the mark is `whenTurnEnds`,
   it becomes `parked(at: now)` before `changed(agent)` and before `reconsider()`. The ending
   therefore never counts as a need (FR-006). The workflow triggers in the same function are left
   exactly as they are (FR-015). An archive transition clears the mark (FR-010).
6. **Only the person's prompt unparks.** The `agents/prompt` case in `DaemonCore+Dispatch` clears
   the mark before calling `prompt(_:)`. That is the socket the Mac and the phone send on. Workflow
   prompts, the restart pick-up and the outcome question call `prompt`/`enqueue` directly and leave
   it alone (FR-009, and the 039 assumption).
7. **Attention**: in `needs()`, the report loop skips parked chats. Permission and form needs are
   left alone, because a question asked mid-turn outranks parking (spec Assumptions). Unread and
   needs-attention counts fall out of the group (FR-004).
8. **Views.** Mac: Park/Unpark in the chat toolbar between Stop and Archive, popping to the
   project on Park as Archive does; the same pair in the card's context menu; a "Parked 3 days ago"
   line on the chat page; and on the row, how long ago it was parked plus its ending, with no
   unread or needs mark. A chat marked to park says "Parks when this turn ends". Phone and iPad:
   Park/Unpark in `ChatMenu`, disabled when stale, and the same row line. One set of words and one
   symbol, both in `Shared` (FR-011, FR-018).

**Order.** The Mac first, end to end, with the daemon methods and grouping it needs, walked with
run-app before anything else is built (memory: settle the UX before building depth). Then the
turn-end promotion and prompt unparking. Then the phone. Agents get no new tool (FR-016), and a
test guards that.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, strict concurrency complete. Unchanged.

**Primary Dependencies**: SwiftUI; AgentsKit / AgentsKitCore. No new package.

**Storage**: The agent's JSON record in `AgentStore`. One new optional key, `parking`. Older
records open as not parked. An older build keeps the key in `unknownFields` and writes it back.

**Testing**: `swift test` in `Packages/AgentsKit` (model, grouping, daemon). Build both schemes with
`xcodebuild -skipPackagePluginValidation`, one after the other. run-app skill for the Mac walk.
The phone walk is Alex's (no Simulator GUI here).

**Target Platform**: macOS app and daemon; iOS/iPadOS Remote.

**Project Type**: Mac app + daemon + iOS remote, sharing AgentsKitCore and `Shared/UI`.

**Performance Goals**: Parked lands within 5 s of turn end (SC-004). In practice it is the same
`changed(agent)` broadcast, well under 1 s. Devices agree within 2 s (SC-005), and the same
broadcast already covers that.

**Constraints**: No new agent state. No transcript entry. No new agent tool. The grouping stays
total and derived.

**Scale/Scope**: ~10 files touched in AgentsKit, ~5 in App, ~4 in Remote, 1 in Shared.

## Constitution Check

`.specify/memory/constitution.md` is the unfilled template, so there are no ratified gates. The
project's standing rules are applied instead:

- **One grouping, derived, never stored.** Kept: `.parked` comes out of `AgentGroup(for:)`, and the
  stored fact is the mark, not the group.
- **One transition table.** Kept: the table is untouched. Parking is not an event.
- **The daemon decides, devices read.** Kept: the mark is on the record, `parkAction` is in Core.
- **Never mutate source to prove a test.** Tests assert the property directly.

Post-design re-check: no violations.

## Project Structure

### Documentation (this feature)

```text
specs/040-parked-chats/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── daemon-api.md
└── tasks.md          # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/Agent.swift            # parking field, codable, parkAction
├── Model/AgentGroup.swift       # .parked case, live order, parked: argument
├── Client/AgentsModel.swift     # group(of:) passes parked; Parked sorted by parkedAt
└── Daemon/DaemonAPI.swift       # agents/park, agents/unpark
Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+Commands.swift    # park(_:), unpark(_:)
├── DaemonCore.swift             # move(): promote whenTurnEnds; clear on archive
├── DaemonCore+Dispatch.swift    # routes; person's prompt unparks
├── DaemonCore+Attention.swift   # report needs skip parked
└── DaemonCore+Projects.swift    # counts pass parked
Packages/AgentsKit/Tests/…       # grouping, record, daemon behaviour
Shared/UI/ParkWords.swift        # label, symbol, help text, "Parked …" line
App/Sources/
├── AppModel.swift               # park / unpark
├── Chat/ChatView.swift          # toolbar button, parked line
└── AgentList/AgentRow.swift     # context menu, row line
Remote/Sources/
├── RemoteModel.swift            # park / unpark
├── Chat/RemoteChatView.swift    # ChatMenu items, parked line
├── Projects/…AgentCard          # row line
└── Preview/FakeDaemon.swift     # the two methods
```

**Structure Decision**: The existing three-target layout. Nothing new except one small shared file
of words.

## Complexity Tracking

None.
