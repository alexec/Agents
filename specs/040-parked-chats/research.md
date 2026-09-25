# Research: Park a Chat to Come Back To Later

Each entry below records a decision, why it was made, and what else was considered.

## R1. A mark on the record, not a state

**Decision**: `Agent.parking: Parking?`, where `Parking` is `whenTurnEnds(since: Date)` or
`parked(at: Date)`. The `AgentState` enum and the transition table in `AgentState.applying` stay
as they are.

**Rationale**: The spec says parking sits on top of how the chat ended (Assumptions, Key
Entities). `archived` is a state, and unarchiving has to rebuild the ending from `endedReason`,
which the table already works hard to get right. A parked state would need the same rebuilding,
plus a way to hold a running turn. A separate mark leaves `state`, `endedReason` and `report`
untouched, so unparking is simply removing the mark (FR-002, FR-008).

**Alternatives**: a `parked` `AgentState`. This was rejected because it cannot hold a turn in
flight, and a new state drops the whole agent from builds that predate the lenient decoding of
`state`. The second alternative was two fields, `parkedAt: Date?` and `parksWhenTurnEnds: Bool`.
That was rejected because it can say both at once, a fourth value the spec does not have.

## R2. Where the group comes from

**Decision**: `AgentGroup.parked`, inserted into `AgentGroup.live` after `.stopped`.
`AgentGroup(for:wantsEyes:report:outcomeAsked:parked:)` takes `parked: Bool` with no default.
Precedence: `archived` → `.archived`; `waitingOnUser` → `.needsAttention`; `parked` → `.parked`;
otherwise the existing rules.

**Rationale**: The grouping is derived and total, and its header comment says why no argument
defaults. Putting `.parked` in `live` means the Mac's `ProjectAgentsView` and the phone's
`ProjectPageView` draw the heading in the right place with no new layout (FR-003, FR-013). A
question asked mid-turn outranks parking, because a blocked turn waits on the person whatever
else is true. The spec's assumption about questions says this for a chat marked to park. The
same holds for a parked chat that a workflow's prompt has woken.

**Alternatives**: a separate Parked section beside `archivedSection`. That was rejected because
it is a second grouping rule in two views, which is the bug 021 removed.

## R3. Which button a chat shows

**Decision**: `Agent.parkAction: ParkAction?` in AgentsKitCore. It is `.unpark` when a mark is
present, `.park` when the chat is not archived, and nil when it is archived.

**Rationale**: FR-012 requires one place every device reads. The toolbar, the context menu and
the phone's menu all switch on it.

## R4. What counts as the person's prompt

**Decision**: The `agents/prompt` case in `DaemonCore+Dispatch` removes the mark when
`request.from == .person`, and then calls `prompt(_:)`. `enqueue` is not changed.

**Rationale**: Workflow prompts (`DaemonCore+Workflows` line 608) and the restart pick-up
(`DaemonCore+Recovery` line 164) build a `PromptRequest` with the default origin, `.person`. They
reach `prompt`/`promptFirst` directly, not through the socket. Only the Mac and the phone send
`agents/prompt` over `daemon.sock`, and agents have no prompt tool (`AppService` offers only
`stop` and `archive` on other agents). The socket route is therefore exactly "a person typed
this" (FR-009). It also keeps the 039 case: a prompt the app sends when a block clears does not
unpark.

**Alternatives**: a new `PromptOrigin.workflow`. That was rejected because it would change what
a workflow prompt does to `report` and `outcomeAsked` today, which is a behaviour change outside
this feature.

## R5. Promoting the mark when the turn ends

**Decision**: In `DaemonCore.move`, after the transition is applied: if `next` is `.finished` or
`.stopped` and the mark is `whenTurnEnds`, set `parked(at: Date())`. If `next` is `.archived`,
set the mark to nil. Both happen before `changed(agent)` and `reconsider()`. The workflow
trigger switch below them is not changed.

**Rationale**: `move` is the one place every state change passes through, including stop,
process death and restart recovery ("by any means", FR-006). Setting the mark before
`reconsider()` means the report need is never raised, so no banner goes out. The triggers read
`next`, not the mark, so FR-015 holds by construction.

**Caveat**: after a silent ending the app asks its outcome question. That turn runs with the
mark already `parked`, so the chat stays in Parked throughout, which is what FR-009 wants. The
restart pick-up of a chat with `whenTurnEnds` keeps the mark. `foundDead` goes to `stopped`,
which would promote it. To match the spec's edge case ("parks when that turn ends"), promotion
is skipped when `event == .foundDead && agent.mayBePickedUpAfterRestart`. That is the same guard
the trigger code already uses for "about to carry on".

## R6. Attention and counts

**Decision**: `needs()` skips `.parked` chats in the report loop only. Permission and form needs
are unchanged. The unread count and needs-attention counts need no code, because they come from
the group.

**Rationale**: FR-004. Permissions stay because of R2's precedence.

## R7. Older phones and `[AgentGroup: Int]`

**Finding**: Swift's `Dictionary` decode with a `CodingKeyRepresentable` key *throws* on a key
it cannot convert. A quick script decoding `{"a":1,"b":2}` into `[G: Int]` gave
`dataCorrupted … Could not convert key`. A phone built before this feature would therefore fail
to decode every `ProjectSummary` whose `counts` held `"parked"`.

**Decision**: The daemon leaves `.parked` out of `ProjectSummary.counts`. Nothing reads that
number: both windows count their own groups with `AgentsModel.counts(in:)`, and the daemon's
`needsInput` reads only `.needsAttention`. `counts` also gets a tolerant decode that drops keys
it does not know, so the next new group does not bring this back.

**Alternatives**: accepting that the phone has to be rebuilt. That was rejected because a phone
that shows no projects at all is a harsh failure for a missing heading.

## R8. The parked line and the words

**Decision**: `Shared/UI/ParkWords.swift` holds the labels "Park" and "Unpark", the symbol
`parkingsign.circle`, the tooltips, and a formatter for "Parked 3 days ago" and "Parks when this
turn ends". Both apps use it (FR-018).

**Rationale**: `ConsistencyTests` already fails on words duplicated across the two apps. One file
keeps them in one place.

## R9. Nothing else needs changing

- **Worktree in use**: `DaemonCore+Worktrees` counts every agent whose `state != .archived`, so a
  parked chat already holds its worktree (FR-014).
- **Agents' tools**: `AppService` gains nothing. A test asserts that no tool name contains "park"
  (FR-016).
- **Spending**: counted over every agent regardless of group. Unchanged.
- **Archived projects**: `needs()` already skips them, and their agents are archived with the
  project.
