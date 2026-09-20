# Research: How It Actually Went

Ten decisions, each read off the code as it stands rather than off a preference.

## R1. Where the outcome is kept

**Decision**: A field on `Agent`, written to the record, beside `suggestedPrompts`.

**Rationale**: Two facts settle it. The project sidebar's "this project wants you" dot is computed
by the *daemon*, in `DaemonCore+Projects.swift:39`, from `agent.group` — so an outcome that only
existed in a window could never light it. And an outcome describes a turn that may sit settled for
days; `Agent.suggestedPrompts` is already on the record for exactly that reason ("so the chips are
still there when the app is opened again on a turn that ended last night").

**Alternatives considered**: In-memory on the client, the way `AgentsModel.filesToShow` holds
show-file. Rejected: `filesToShow` is deliberately ephemeral because a file worth looking at now is
not worth reopening next week, and the daemon stores nothing for it. An outcome is the opposite —
it is the account of the work, and losing it on a window close would put the feature back where it
started.

## R2. Grouping without a new `AgentState`

**Decision**: `AgentGroup` gains a third parameter. `AgentState` gains nothing.

**Rationale**: The code already argues this case, in `AgentGroup.init(for:wantsEyes:)`:
`waitingOnUser` carries `holdsRuntime` and `hasTurnInFlight` with it, so an agent put there would
start queueing prompts and the transition table has no way out except answering a permission. An
agent that reported **needs an answer** has given the turn back and its runtime has been released by
`finishTurn`; it must take a prompt immediately, which is precisely what FR-014 requires. A sixth
`AgentState` case would also mean new entries for all nine `AgentEvent`s.

**Alternatives considered**: (a) A new `AgentState.needsInput`, rejected above. (b) Deriving the
group in each view, rejected because `AgentGroupTests` exhausts the mapping today and that guarantee
— an agent is in exactly one group, never none — is worth more than the saved parameter.

## R3. The colour collision

**Decision**: Orange stays the one "wants you" colour. Green narrows from *finished* to *reported
done*. **Nothing to do** and an unaccounted-for ending go grey.

**Rationale**: `AgentRow.StatusIcon` says "Grey, all of it, except the one that wants you" and then
tints `.finished` green, which is an inconsistency already in the tree. FR-011 forces the question,
and three marks are the most a row can carry legibly:

| What | Symbol | Tint |
|---|---|---|
| done | `checkmark.circle.fill` | green |
| nothing to do | `checkmark.circle` | secondary |
| needs an answer | `questionmark.circle.fill` | orange |
| partly done | `circle.lefthalf.filled` | orange |
| stuck | `exclamationmark.triangle.fill` | orange |
| not accounted for | `questionmark.circle` | secondary |

The pairing is deliberate: filled means somebody said so, hollow means nobody did, and orange means
you. A hollow grey question mark reads as *unknown* where the filled orange one reads as *asked*.

**Alternatives considered**: Keeping green for every settled ending, which would leave a reported
**stuck** and a reported **done** wearing the same tick and lose the feature's point on the one
surface people actually scan.

## R4. Asking once, and only once

**Decision**: In `finishTurn`, after the state has moved to `.finished` with `.endTurn` and before
`drainQueue`: if there is no report, no queued prompt, and the agent has not already been asked,
enqueue the question through the ordinary prompt path and set a persisted flag. The flag is cleared
only when a prompt from the *person* is enqueued.

**Rationale**: `finishTurn` is already the one place a normal ending passes through, and `enqueue`
is already the one way anything reaches a runtime, so the question inherits the whole of the
existing machinery: it starts the runtime back up, it is recorded, its usage is counted by
`finishTurn` the next time round (FR-024), and it cannot race a turn in flight. Gating on an empty
queue is what makes FR-023's "a prompt from the person supersedes the ask" true by construction
rather than by check. The flag rather than a counter is enough because there is only ever one.

**Alternatives considered**: (a) Raising an elicitation — impossible, elicitation hangs off a turn in
flight and there is none. (b) Asking synchronously before the turn is allowed to end — the runtime
has already returned its stop reason by then; there is nothing left to ask. (c) Re-asking until
answered — rejected on FR-021 and on cost: a runtime that never calls the tool would double the cost
of every turn forever.

## R5. Marking a prompt as the app's own

**Decision**: `TranscriptEntry.Kind.userMessage` gains an origin, defaulted to the person.
`QueuedPrompt` and `DaemonAPI.PromptRequest` carry the same.

**Rationale**: FR-022 needs this to be structural. The precedent in the tree is not structural:
`DaemonCore+Workflows.promptText(for:run:)` marks a workflow's prompt by appending a parenthetical
to the text — readable, but indistinguishable to any code, and a view cannot draw it differently.
Because `TranscriptEntry.Kind` is coded by hand in `TranscriptEntry+Coding.swift`, an added key on an
existing case is the cheapest possible change: an older build reads the record, does not see the key,
and renders the line as the person's, which is wrong only in a build that has no concept to be right
about.

**Alternatives considered**: (a) A new `.appMessage` kind — rejected because the entry genuinely *is*
the user message sent to the runtime, and a new kind would fall out of `coalesced`, `text` and
`blocks`, each of which would need a case to put it back. (b) The parenthetical convention —
rejected on FR-022. Making workflow prompts use the same origin is an obvious follow-on and is
deliberately **not** in this feature's scope.

## R6. The notification requirement is somebody else's

**Decision**: 014 ships one predicate, `Agent.needsAPerson`. It ships no notifier.

**Rationale**: FR-016 says an outcome needing a person must reach the person "through the same
notification path as any other agent that needs them". That path does not exist yet: nothing in
`App/`, `Remote/` or `Packages/` references `UNUserNotificationCenter` or APNs, and 005's own
`tasks.md` has 66 of 86 tasks still open, including every notification task. So the honest reading of
FR-016 is that 014 must make an outcome needing a person *indistinguishable in kind* from a
permission request, so that when 005's notifier is built it covers both without knowing about this
feature. One predicate on `Agent`, read by the group and by the project counts, is that.

**Alternatives considered**: Building a notifier here. Rejected — it is 005's requirement, 005's
design and 005's pairing story, and a second one built in this feature would have to be taken out
again.

## R7. The tool's shape

**Decision**: One tool, `report_outcome`, with two required arguments: `outcome`, a string enum of
five, and `message`, a string.

**Rationale**: It follows `manage_workflows`, whose comment gives the reason — "one tool with an
action rather than four, because that is how the surface reads to a model: an agent that has found
this once knows the whole of it". Five tools, or a boolean `needsInput`, would each make the agent
assemble the answer from parts. A closed enum is also what makes FR-002's "no free-form outcome"
enforceable at the schema, so most bad reports never reach the daemon.

**Alternatives considered**: (a) An optional `question` field distinct from `message` — rejected,
FR-004 already makes the message *be* the question for that outcome, and a second field invites both
to be filled in and disagree. (b) A structured list of what was and was not done — rejected as a form
nobody would fill in honestly; the row has one line.

## R8. How a report is refused

**Decision**: `noSuchAgent` (-32005) for a token that no longer speaks for an agent, matching
`suggestPrompts` and `showFile` exactly. Plain `invalidParams` with a sentence for an empty message
and for a report arriving while a permission or elicitation is outstanding. No new error code.

**Rationale**: `showFile` already refuses an out-of-scope path with `invalidParams` and the same
sentence a refused read gets — "an agent that is told the rule once does not need to be told it
differently by every door". A new code would be a second door.

## R9. A message too long

**Decision**: Trim to 1,000 characters. Never refuse on length.

**Rationale**: `SuggestedPrompt.init(wire:)` sets the precedent and gives the reason — losing the
row over one bad entry would be worse than trimming it. An empty message is different and *is*
refused (FR-003), because an outcome with no words is exactly what the app already had.

## R10. The workflow row does not get its own copy

**Decision**: `WorkflowRow` looks the agent up and reads its report. `WorkflowOutcome.ran` is not
extended to carry one.

**Rationale**: `WorkflowOutcome.ran(agentID:at:)` already holds the agent's id, and the client
already has every agent. Copying the report into the workflow record would create a second place for
it to be stale — and the record is saved by `record(_:for:)` at fire time, before the agent has
done any work, so it would have to be written twice.

**Alternatives considered**: A third `WorkflowOutcome` case. Rejected: that enum answers "what did
the *fire* produce", and the answer is still "it ran". How the run went is the agent's to say.
