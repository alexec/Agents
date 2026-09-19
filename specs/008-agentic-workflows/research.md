# Phase 0 Research: Agentic Workflows

Six questions the spec left to the plan. Each is settled here, with what was rejected.

---

## 1. How are workflow files discovered and kept current?

**Decision.** One `FolderWatch` per live project, rooted at the project folder, with its callback filtered to paths under `.agents/` and debounced by 250ms. A match triggers a rescan of that project's `.agents/workflows` directory alone. Projects are also rescanned when the daemon learns of a project change, when the workflow tool writes a file, and once at daemon start.

**Rationale.** `FolderWatch` already exists for the files pane and already does the hard part: FSEvents reports at directory granularity and coalesces bursts, which is why a build that writes four thousand files produces a manageable number of events rather than four thousand. The filter is a string comparison on paths we were handed anyway, and the rescan reads one directory holding a handful of small files. SC-001 allows five seconds; the 0.2s coalescing interval plus a 250ms debounce plus a directory read is comfortably inside that.

**Alternatives considered.**

- *Watch `.agents/workflows` directly rather than the project root.* Cheaper per event and wrong at the boundary that matters: FSEvents on a path that does not exist yet reports nothing, so the first workflow anyone ever adds to a project — the exact moment the feature has to work — would not be noticed until something else prompted a rescan.
- *Poll each project's folder on a timer.* Simple and either too slow for SC-001 or too expensive at the frequency that would satisfy it.
- *Only rescan on daemon start and on tool writes.* Would work for agent-authored workflows and break the hand-written path that user story 1 is built on.

**Consequence for the watchers' lifetime.** One watcher per non-archived project, created when the project list is loaded or changes, torn down when a project is archived or goes away. Projects whose folder does not exist get none.

---

## 2. Where does the scheduler live, and how does it survive sleep?

**Decision.** In `DaemonCore`, as a single `Task` ticking every 15 seconds. On each tick it takes `Date()`, and for every workflow with a schedule trigger asks whether a due time falls in the interval between the last tick and now. There is never a sleep-until-the-next-fire.

**Rationale.** Two reasons to be in the daemon rather than the app: the daemon already outlives the window by design — "holds the runtimes, writes the record, answers the app, and keeps going when there is no window" — and the app is where a project page might not be open. Workflows belong to the project, not to what is on screen.

Two reasons for a short repeating tick rather than sleeping until the next due time:

- **Machine sleep.** `ContinuousClock` advances across suspend and `SuspendingClock` does not, so a sleep-until-due is a bet on which clock semantics hold across a lid close. A tick that reads wall-clock `Date()` each time needs no such bet: after a suspend, the first tick back sees a large gap and handles it explicitly.
- **Time zones and DST.** A due time computed once and slept on is wrong the moment the machine moves time zone or the clocks go back. Recomputing from `Date()` and the current calendar every 15 seconds makes both a non-event.

15 seconds against SC-008's one minute leaves margin for a tick that lands during a busy moment. The work per tick is a comparison per workflow over tens of workflows — nothing.

**Alternatives considered.**

- *One `Task.sleep` per workflow until its next fire.* Reads elegantly, multiplies the sleep-semantics bet by the number of workflows, and has to be cancelled and rebuilt on every file change.
- *A `DispatchSourceTimer` or `Timer` on a run loop.* No advantage over a `Task` inside the actor that owns the state, and would need hopping back onto the actor anyway.
- *`launchd` with a calendar interval.* Would fire while the app is closed, which the spec explicitly puts out of scope, and would mean a second thing to install and keep signed.

---

## 3. How is a missed fire told apart from one that simply has not happened?

**Decision.** The daemon persists a heartbeat — `lastTickAt` — in the workflow state file, updated on every tick. Each workflow persists `lastFiredAt`. On a tick, a due time in the past that is after the workflow's `lastFiredAt` is either fired, or — if it falls inside a gap where `now - lastTickAt` is more than a few ticks — recorded as a `missedWhileClosed` refusal and not fired.

**Rationale.** The heartbeat is the only honest way to answer "was anyone listening at 9am?" without asking the operating system about its own uptime. It costs one small write every 15 seconds and makes FR-014 and the corresponding edge case mechanical rather than heuristic. Recording the miss as a refusal rather than saying nothing is what SC-003 demands: no fire is ever silent.

**Alternatives considered.**

- *Fire everything missed on start.* Explicitly rejected by the spec — opening the app after a weekend would start a queue of agents nobody asked for.
- *Say nothing about missed fires.* Indistinguishable from a broken trigger, which is the failure mode user story 3 exists to eliminate.
- *Read system uptime.* Answers whether the machine was up, not whether the daemon was, and the daemon is what matters.

**Note.** Consecutive misses collapse under the same repeat-count rule as any other refusal, so a fortnight away is one line saying so with a count, not a fortnight of rows.

---

## 4. How is a workflow write confirmed, given the runtimes disagree about asking?

**Decision.** The daemon raises its own confirmation. A workflow write from the tool creates a pending confirmation, broadcasts it, and blocks the tool call until it is answered or times out. Separately, `autoAllowed(_:)` is narrowed so that it waves through only the suggestion and show-file tools, never the workflow tool.

**Rationale.** This is the one place the existing shape does not already fit, and the reason is behavioural rather than structural. `autoAllowed(_:)` exists because Copilot asks before every tool call and a sheet asking whether the app may show the app's own suggestions is a question with no information in it. Workflow writes are the opposite: the question carries all the information there is. But the inverse problem is worse — the Claude adapter frequently does *not* raise a permission request for an MCP tool call at all, so a design that waits for the runtime to ask would be strict under Copilot and wide open under Claude. The only way FR-035 holds across every runtime is for the confirmation to come from the side that is the same in all four.

The machinery already exists in the shape needed. `pendingPermissions` and `elicitations` are both dictionaries of blocked requests held on the actor precisely because "the question can arrive while no window is open", each broadcast to windows and answered by a JSON-RPC call back. The workflow confirmation is a third of the same kind.

**What the confirmation says.** FR-036 requires plain language, so the confirmation carries the rendered trigger summary and mode — *Runs every weekday at 9:00am, in a new agent* — not a diff and not a path. The same renderer serves the project page row, so the two cannot drift.

**No window open.** `showFile` already sets the precedent: rather than swallow the call, it refuses with "No window is open, so there was nowhere to show it." A workflow write with `connectionCount == 0` is refused the same way, in the same voice. Nothing is written.

**Timeout.** A confirmation nobody answers refuses after two minutes, so a runtime is not left hanging on a person who walked away. The agent is told which it was.

**Alternatives considered.**

- *Trust the runtime's own permission request.* Rejected above: unreliable in the direction that matters.
- *Write the file and mark it pending review.* This is the `enable on review` model that clarification explicitly turned down in favour of permission-on-write.
- *Reuse `pendingPermissions` directly rather than a parallel structure.* Tempting, and wrong: a `PermissionRequest` is a thing a runtime asked and is answered back into an ACP session. A workflow confirmation originates with the daemon and is answered by doing or not doing a file write. Sharing the type would mean a `PermissionRequest` with no session to answer.

**Reads are not confirmed.** FR-034 — listing and reading raise nothing. They are scoped by `FolderScope` to the calling agent's project, which is the same check `showFile` already makes, and reading a file the agent could read with its own tools anyway is not worth a sheet.

---

## 5. Where do lifecycle triggers hook in?

**Decision.** Two hooks, both in existing single-funnel code.

- `DaemonCore.move(_:on:endedReason:)` is where every agent state transition happens, and it already computes the resulting state. A workflow hook placed after `changed(agent)` and `record(...)` sees `finished`, `stopped`, and every other landing exactly once.
- `DaemonCore.handle(_:agentID:)` is where `.permissionRequested` and `.elicitationRequested` arrive. The permission hook goes after the pending request is held and broadcast, so a workflow fires while the request is still outstanding, as FR-009 and the acceptance scenario require.

**Rationale.** `move` returning `nil` for a transition that must not happen means the hook cannot fire on a non-event, and the state machine's exhaustive tests already guarantee which events land where. There is no new event bus, no new notification, and no second path an agent's life can take.

**The obvious trap, and the one rule that avoids it.** An agent started by a workflow finishing is exactly what the `agent finished` trigger watches for, so the naive hook loops on the first workflow anyone writes. Chain depth is what stops it: the hook reads the triggering agent's `startedByRun`, and a fire whose depth would exceed the limit is refused and recorded. The limit is deliberately not configurable per workflow — a runaway workflow able to raise its own limit is not stopped.

**Re-entrancy.** `DaemonCore` is an actor and the hook is called from inside it, so firing must not `await` on anything that could call back into `move`. The hook computes the decision synchronously and starts the run on a detached task, in the same shape `beginTurn` already uses for `turnTasks`.

---

## 6. How does the front matter leave room for triggers that come later?

**Decision.** Triggers decode into a closed enum with one open case: an unrecognised trigger keeps its raw name and any keys it came with, and the workflow is listed as not yet supported. Unknown top-level front-matter keys are preserved on the model, following the `unknownFields` pattern already on `Agent`.

**Rationale.** FR-013 asks for exactly this, and the codebase already answers the same question the same way in three places — `Agent.unknownFields`, the `unknownUpdate` and `unknownNotification` session events that are logged rather than thrown. A file written by a newer version, or by hand against next year's documentation, must be inert and visible rather than an error that makes the whole file unreadable.

The deferred triggers named in the spec — file and glob changes, git events, GitHub PR and CI — need nothing reserved beyond this. Each is a new case in the enum and a new watcher; no existing file changes shape.

**What malformed means, then.** A file is malformed only when the front-matter block itself cannot be read as YAML, or when a required key (`on`, or the body) is missing entirely. An unrecognised trigger name, an unknown key and an unknown mode are all *understood but not supported*, which is a different row on the project page and a different message.

**Where the boundary sits.** `FrontMatter.strip(_:)` already exists in Core and handles the positional rule — `---` on the first line is a fence, `---` anywhere else is a horizontal rule — which is the part that is easy to get backwards and eats the top of a document. Workflow parsing reuses it rather than writing a second, subtly different one.

---

## Resolved

No `NEEDS CLARIFICATION` markers remain. The five decisions carried in from `/speckit-clarify`, plus the refusal-visibility requirement, were settled before the spec was written and are recorded in its Clarifications section.
