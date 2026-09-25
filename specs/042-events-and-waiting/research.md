# Research: Events and Waiting

These are the decisions behind [plan.md](plan.md). Each one gives the decision, why it was
made, and what else was considered. Code references are to `main` at `d44e74a`.

## R1. One funnel: `raise`

**Decision**: There is one actor-isolated function, `DaemonCore.raise(_ draft: EventDraft) -> Event`.
Every source calls it, and nothing else matches waits or workflows. It never awaits between
giving out the position and matching waits, so a wait made in the same instant is either before
the event (and matched) or after it (and waits from after it).

**Rationale**: Today, "something happened" goes three separate ways:

- `workflowsRespond(to:)` for agent events
- `firePullRequestTriggers` for pull requests
- `workflowRunFinished` for `workflow-completed`

A fourth route for waits would make four places that could disagree. FR-024 and User Story 3
come down to having one route.

**Alternatives**: Adding waits beside each existing route was rejected, because there would be
four matchers and no single place to record consequences (FR-027). A general pub/sub bus with
subscribers registered at runtime was also rejected. There are two subscribers, waits and
workflows, and a bus would hide the order they run in.

## R2. Three tools, not five

**Decision**: There are three tools:

- `wait_for_event`, with `action`: `wait` (the default), `recent` or `list`
- `cancel_wait`
- `publish_event`

**Rationale**: The more tools an agent is given, the harder each one is to find. Reading recent
events and listing the catalogue are only ever done just before a wait, to pick a starting
position (FR-010) or a name (FR-011). That makes them the same decision as the wait, so they
belong on the same tool. Cancelling is a different act with a different effect, and folding it
into "wait with nothing" would hide it.

**Alternatives**: Five tools (`wait`, `cancel`, `recent`, `list`, `publish`) mirror the spec
literally but add two tools to the tool list of every agent. One `events` tool with every action
was rejected because publishing has a rate limit and a different permission shape. Claude and
Cursor ask permission per tool, and the person should be able to allow waiting without allowing
publishing.

## R3. The wait lives on the agent record, not on the report

**Decision**: `Agent.eventWait: EventWait?` is written with the record, and it is cleared on a
match, a timeout, or cancellation. The agent's group is `.blocked` while it has an open
`eventWait` and it isn't in a turn.

**Rationale**: 039 put `Block` on the report because a block arrives *with* the report and the
report's lifecycle is the block's. A wait is made *mid-turn*, by a tool call. The turn may then
end with `finish_turn` done, blocked, or with nothing at all. If the wait lived on the report,
the report would replace it. On the record, it survives whatever ending the turn reports, and
survives restarts with the record (FR-014).

**Alternatives**: Folding event waits into `Block` was rejected, because the report arrives after
the wait and replaces it. Keeping a separate `waits.json` was also rejected: it would be one
more file to keep in step with the agent it describes, and the phone already receives agent
records.

## R4. Two kinds of wait look the same

**Decision**: `WaitStatus.status(for: Agent, names:)` returns one `line` and one `mark`, and it
takes either an open `Block` with agent waits or an open `eventWait`. A block on "Fix login"
reads `◷ Waiting for "Fix login" to finish`. A wait on `agent.finished` with `agent: <that id>`
reads the same, because the formatter turns that one pattern into the same words (FR-012). The
capsule, the row mark and the phone card all call this function.

**Rationale**: 039's `finish_turn blocked` is kept. It is live, proven, and in every runtime's
briefing. Rewriting it as an event wait would move every block onto a new mechanism for no gain
the person can see. FR-012 asks for them to be shown the same, not built the same.

**Alternatives**: Converting `blocked` into an `agent.finished` wait was rejected. It is a large
change to 039's resume rules (all waits closed, `checkAgainAt`, circles) and adds risk to a
feature that has only just been merged. It can be done later, behind `WaitStatus`, with no
change to the UI.

## R5. Holding the call, and waking

**Decision**: Copy 036's shape exactly:

- A `CheckedContinuation` is parked in `openEventWaits[agentID]`, one per agent.
- A task answers "still waiting" after `callHoldLimit`, which is 45 s and the same value as
  `leaseWaitLimit`.
- A match while the call is open answers the continuation.
- A match after the call has closed clears the wait and queues an app prompt in the same actor
  step, as 039's `queueResume` does. The prompt is then sent through `prompt(... from: .app)`.

A wait's deadline arms one timer for the earliest deadline, like the lease timer.

**Rationale**: This has been proven live with Claude, Grok and Cursor (036). Using one number for
both means there is only one thing to re-measure.

**Alternatives**: Returning at once and always waking by prompt was rejected. It costs a turn
restart even when the event is seconds away, which is the common case for
`agent.finished` of a helper.

## R6. Positions and "wait from"

**Decision**: A position is an `Int64` that increases and is never reused. The next value is
kept in `events-state.json`, which is written before the event line is appended, so a crash
between the two leaves a gap, never a duplicate. Every tool reply that shows events includes
`position`, and so does the `recent` answer. `wait_for_event(from: N)` first scans the log for
events after N that match. If one is found, it answers at once.

A coalesced repeat keeps its first position and increments `count`. A wait from before that
position matches it once. A wait from after it does not see the repeat: it is the same event
(FR-031).

**Rationale**: FR-010 describes a race: the agent checks, the event happens, then the agent
waits. The agent needs a cursor to close that race. A timestamp could close it too, but
timestamps collide and depend on the clock.

**Alternatives**: A "since" time was rejected because two events in one millisecond are
ambiguous. So was matching the last N events on every wait, because it could wake an agent on a
stale event, which the spec's first edge case forbids.

## R7. Moving agent and workflow triggers behind `raise`

**Decision**: The lifecycle funnel calls `raise(.agent(.finished …))`. `raise` records the
event, matches waits, then calls the existing `workflowsRespond` logic (renamed
`fireWorkflows(for: event)`) for the workflows. `deferredLifecycleEvents` still holds workflow
matching until `workflowsAreStarted`. The event itself is logged at once, so the log is
complete even for events that arrive during start-up. `workflowRunFinished` raises
`workflow.completed`, and the old `workflow-completed` trigger fires from that event with
`depth: run.depth + 1`, exactly as today.

The depth an event carries is computed by the source and stored on the event (`chainDepth`), so
anything fired from it takes that depth. Agent events use `workflowChainDepth(causedBy:)`,
workflow completions use `run.depth + 1`, and a publish uses the publisher's depth plus 1
(FR-020). Machine, branch and pull-request events use 0.

**Rationale**: This gives one route with the same depth rules. The tests pinned to today's
behaviour are the safety net, so they must stay green without being edited.

## R8. Pull-request events alongside 038's own triggers

**Decision**: Each refresh diffs the previous list (kept in memory, and in `PullRequestStore`
across restarts) against the new one, per pull request:

| Change | Event |
|---|---|
| The number is new | `pull_request.opened` |
| `checks` goes from anything else to `.failing` | `checks_failed` |
| `checks` goes to `.passing` | `checks_passed` |
| `review` goes to `.approved` | `approved` |
| `review` goes to `.changesRequested` | `changes_requested` |
| `conflicts` goes to `.conflicting` | `conflicts` |
| `countableComments` has a newer `createdAt` than the last seen | `review_comments` |
| The number has gone from the open list | One follow-up `gh api graphql` for `pullRequest(number:){state}` gives `merged` or `closed`. If it can't be reached, nothing is raised, and it is tried again at the next refresh. |

Each of these also raises `pull_request.changed` with `what: <name>`.

038's three hyphenated triggers keep firing from `PullRequestChanges.unfired`, which tracks what
has been fired per workflow and runs the R9 refusals. A dotted `pull_request.*` trigger in a file
goes through `raise` like any other event. `raise` records a 038 fire as a consequence of the
matching event, by pull request number and trigger, so the log still shows it.

**Rationale**: 038's per-workflow "unfired" bookkeeping is what stops a babysitter re-running on
a change it has already handled across restarts. It is proven live, and replacing it with event
matching would re-open every one of those cases. The events and the old triggers see the same
list, so they cannot disagree about what changed.

**Alternatives**: Routing 038's triggers through `raise` and dropping `unfired` was rejected: it
would change a live-proven feature's firing rules, and SC-006 says nothing may change. Raising
events only from 038's triggers was rejected because it misses `approved`, `merged`, `closed`
and `opened`.

**The first refresh after start** only seeds the previous list and raises nothing, because
events are never invented for the time the app was not running (FR-014). The exception is a
merged or closed pull request that was open in the stored list: that is raised when noticed,
carrying the time it was noticed (spec, edge cases).

## R9. `branch.moved`

**Decision**: The project's existing `FolderWatch` is started for every project, not only ones
with workflows, and a second callback is added. It looks at changed paths under `.git/refs/`,
`.git/packed-refs`, `.git/HEAD` and `.git/worktrees/*/HEAD`. Changes are debounced for 1 s.
The daemon then runs `git rev-parse` for the default branch and for each branch that a live
agent's worktree is on. It compares the results with the tips kept in `events-state.json` and
raises one `branch.moved` for each tip that changed, with `from` and `to`.

At start, tips are read and stored without raising anything. A tip that differs from the stored
one is raised as a move, carrying the time it was noticed.

**Rationale**: The watcher already exists and FSEvents covers `.git` under the root. Polling git
would add a subprocess per project every few seconds.

**Alternatives**: Git hooks were ruled out by the spec (scripts may not raise events in this
version) and would mean writing into the person's repository.

## R10. Mac and person events

**Decision**: A `MachineWatch` protocol, with an IOKit implementation behind
`#if canImport(IOKit)`, and a fake for tests.

- **Sleep and wake**: `IORegisterForSystemPower`. `kIOMessageSystemWillSleep` raises
  `mac.sleep` and then allows the sleep. `kIOMessageSystemHasPoweredOn` raises `mac.wake`.
  Delivery is on the main queue, which agentsd keeps running with `dispatchMain()`.
- **Lock**: `DistributedNotificationCenter` observes `com.apple.screenIsLocked` and
  `com.apple.screenIsUnlocked`. They raise `person.away` and `person.back` with `why: locked`.
- **Idle**: a 30 s timer reads `HIDIdleTime` from `IOHIDSystem`. Crossing 300 s raises
  `person.away` with `why: idle`, and coming back under it raises `person.back`. Not while
  locked, because locking already said so.

**Rationale**: The daemon runs without the app window. On a headless Mac or at the login screen,
a watch that relied on the app would miss the one wake that matters, the overnight one.

**Spike first (Phase 6, ten minutes)**: confirm that the lock notifications arrive in `agentsd`
under launchd. If they do not, the app sends lock and unlock through the `presence/report` it
already sends, and the daemon raises the events from that. Sleep and wake from IOKit don't
depend on the spike.

**As built (T058, 2026-09-25)**: the spike was not run as planned, because it needed the
screen locked while Alex was at it, and because `agentsd` parks its main thread in
`dispatchMain()` with no CFRunLoop, so a distributed notification would likely never be
delivered to it anyway. Instead the watch needs nothing delivered:
- Sleep and wake: `IORegisterForSystemPower` with `IONotificationPortSetDispatchQueue`, so the
  power messages arrive on a dispatch queue.
- Lock: `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, read every 10 s.
- Idle: `HIDIdleTime` from `IOHIDSystem`, read every 10 s.

Both reads were probed from a plain command-line process (session dictionary present,
unlocked; idle 449 s). The sleep/wake and lock walks with the real Mac are quickstart §4.

**R7, as built**: today's nine trigger names keep firing from where they always did, and
only gain a causing event, so the log shows their fires. Only the new dotted names are
matched in `raise`. Moving the old ones behind `raise` as well would have changed a
live-proven firing path for no difference the person can see, and risked firing twice.

## R11. `cost.limit_reached`

**Decision**: The event is raised where the daemon already refuses for a limit:

- `isDayLimitReached`, which gives `limit: day` and Mac scope
- `agent.isAtCostLimit`, which gives `limit: agent` and project scope, with the agent

It is raised once per crossing, remembered in `events-state.json` by day and limit, not on every
refusal.

## R12. Workflow triggers on events

**Decision**: File syntax is today's own, extended:

```yaml
on:
  - agent-finished                  # old name, unchanged: .agentFinished
  - mac.wake                        # bare dotted name: .event(EventPattern("mac.wake"))
  - pull_request.merged:            # name with detail filters under it
      number: 41
  - custom.build_green
  - pull_request.*                  # a whole subject
```

A name is looked up in this order:

1. Today's nine names give today's cases.
2. A catalogue name, `subject.*` or `custom.<name>` gives `.event`.
3. Anything else gives `.unrecognised`, as today.

Filter keys must be details the kind carries. An unknown key is a file error that names the
valid keys, the way a pull-request trigger "takes no settings" today.

Old cases map to patterns (`agentFinished` → `agent.finished`, and `agentStopped` →
`agent.stopped` plus `agent.failed`), and `summary` uses the catalogue sentence, so the page
says the same thing about both spellings (FR-022). `schedule` stays its own case.

**Wire**: `.event(p)` encodes as `.unrecognised(name: p.name, keys: p.filters)`. An older
decoder reads it as a trigger it does not know, and the new decoder turns it back into `.event`
when the name parses (FR-025, 038 R11).

**Triggering mode**: refused with `noTriggeringAgent` for a kind with no `agent` detail
(FR-023). For pull-request kinds, the triggering agent is 038's last-active agent in the
worktree.

## R13. Consequences

**Decision**: Consequences are appended to the event in memory and written as a separate
`{"consequence": …, "position": N}` line in the same `events.jsonl`, so the log stays
append-only. On load, the lines are folded into their event. There are four kinds:
`woke(agent)`, `fired(workflow, agent?)`, `refused(workflow, reason)` and
`couldNotWake(agent, reason)`.

A workflow's `WorkflowOutcome.ran` and `.refused` gain `causingEvent: EventPosition?`, decoded if
present, which feeds the link from the workflow row (FR-030).

## R14. Retention and coalescing

**Decision**: Pruning happens at start and hourly. The log keeps events newer than 7 days, capped
at 10,000 by dropping the oldest first. The file is rewritten to a temporary file and renamed
over the old one.

A new event is folded into the last event when it has the same name, the same scope and equal
details, and the last one is less than 60 s old. The last event's `count` and `lastAt` go up, a
`{"repeat": N, "at": …}` line is appended, and waits and workflows are still matched against it
(FR-031 records it once, but it still happened).

Waits are one-shot, so a repeat can wake at most one waiter once. Workflows keep their
one-run-at-a-time rule.

## R15. Scope and privacy

**Decision**: An event's scope is `.mac` or `.project(folder)`.

- `wait_for_event`, `recent` and patterns are filtered to the caller's project plus `.mac`
  (FR-015). Naming another project's pull request just never matches. It is not refused,
  because the pull request number alone doesn't say which repository is meant.
- The page sees everything.
- The phone sees everything the Mac shows. Events are made from the same fields the phone
  already receives (titles, numbers, branch names), never transcript text (FR-004).
- A published event's message is capped at 500 characters and its details at 10 string pairs of
  200 characters each.

## R16. Failure codes

`eventRefused = -32050`, for an unknown name, a filter the kind doesn't have, another
project's scope, a name outside `custom.`, or the publish limit. `noWait = -32051`, for
cancelling with nothing to cancel. These are taken from -32050, clear of 036's -32035 and 038's
-32040 to -32044, with room for 037's lane.
