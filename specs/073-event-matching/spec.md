# Feature Specification: Finer event matching, step 1

**Feature Branch**: `agents/work-github-issue-99`

**Created**: 2026-10-02

**Status**: Draft

**Input**: Issue #99, "Events: finer matching for workflow triggers and waits". Step 1 of the recommendation in [`specs/research/099-event-matching.md`](../research/099-event-matching.md), with that doc's four decisions taken as recommended:

1. A list under `labels` means "has any of these".
2. Sentence details become codes, and old sentence values keep matching.
3. Copy as trigger stops copying `agent`.
4. Scope is unchanged: no hearing other projects' events.

## Why this feature exists

A workflow trigger or a wait can name an event and narrow it by the event's details. Today that is too coarse in three ways:

- **Agent events say almost nothing about the agent.** They carry its id and one or two specifics. "An agent labelled `bug` finished" and "a Claude agent failed" can't be said, because the event doesn't carry labels or a runtime.
- **A filter holds one value, compared exactly.** "Finished `done` or `nothing_to_do`" needs two triggers. A wait asked for both silently waits for every outcome, because the wait tool drops the list it doesn't understand.
- **Some details are English, not codes.** `agent.failed`'s `reason` is a sentence such as "rate limited, and still limited after retrying". A filter must match that sentence exactly, so in practice nobody can narrow by it. A mistyped value, such as `outcome: complete`, is accepted and then never matches.

Step 1 fixes the details and adds "any of". Negation (`not`) and globs (`release/*`) are step 2, in their own spec. The matcher stays one matcher: workflow triggers and waits both ask the same pattern whether an event matches.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Narrow by the agent's labels and what became of it (Priority: P1)

Alex wants a workflow that writes up every bug fix: whenever an agent labelled `bug` finishes and is parked, the workflow starts. Alex writes:

```yaml
on:
  - agent.finished:
      labels: bug
      afterwards: park
```

An agent can do the same with a wait: "wake me when any agent labelled `deploy` finishes".

**Why this priority**: These are the two examples in #99, and the reason the issue exists.

**Independent Test**:
- Write the trigger above in a scratch project.
- Finish three agents: one labelled `bug` that parks itself, one labelled `bug` that stays, and one labelled `perf` that parks.
- Only the first one runs the workflow.
- An agent waiting on `agent.finished` with `{"labels": "deploy"}` is woken by an agent labelled `deploy`, and not by one without that label.

**Acceptance Scenarios**:

1. **Given** the trigger above, **when** an agent labelled `bug` and `p1` finishes and asked to be parked, **then** the workflow runs.
2. **Given** the trigger above, **when** an agent labelled `bug` finishes and is not parked, **then** it does not run.
3. **Given** the trigger above, **when** the person parked the agent while its turn was still going, and the turn then finishes, **then** the workflow runs. Parked afterwards is parked, whoever asked for it.
4. **Given** `labels: [bug, regression]`, **when** an agent labelled `regression` finishes, **then** the workflow runs.
5. **Given** `agent.archived` with `by: you` and `labels: bug`, **when** the person archives an agent labelled `bug`, **then** the workflow runs.
6. **Given** `agent.*` with `started_by: workflow`, **when** any agent a workflow started does anything that raises an agent event, **then** the workflow runs, except on its own agents, as #102 already ensures.
7. **Given** an agent's label was added after the event, **when** the event is read later, **then** it still shows the labels the agent had when it happened.

---

### User Story 2 - Say "any of" in one filter, and never have a filter dropped (Priority: P1)

Alex wants one trigger for "an agent finished with `done` or `nothing_to_do`", and another for "the nightly workflow's agent ended `stuck` or `partly_done`":

```yaml
on:
  - agent.finished:
      outcome: [done, nothing_to_do]
  - workflow.completed:
      workflow: nightly
      outcome: [stuck, partly_done]
```

**Why this priority**: "Any of" is the commonest narrowing after a single value. Without it, today's silent widening in waits stays.

**Independent Test**:
- Write each trigger and raise matching and non-matching events on a scratch root.
- Start a wait with `{"outcome": ["done", "nothing_to_do"]}` and check that a `stuck` finish does not wake it.

**Acceptance Scenarios**:

1. **Given** `outcome: [done, nothing_to_do]`, **when** an agent finishes `nothing_to_do`, **then** the workflow runs; **when** one finishes `stuck`, **then** it does not.
2. **Given** a wait with `where: {"outcome": ["done", "nothing_to_do"]}`, **when** an agent finishes `stuck`, **then** the wait keeps waiting.
3. **Given** a wait with a `where` value that is neither text, a number, a true/false nor a list of those, **when** the wait is made, **then** it is refused, with a sentence saying what a value can be. Nothing is dropped.
4. **Given** `workflow.completed` with `outcome: stuck`, **when** the nightly workflow's agent ends `stuck`, **then** the workflow runs.
5. **Given** a list with one value, such as `outcome: [done]`, **then** it means exactly what `outcome: done` means.

---

### User Story 3 - Narrow failures, stops and refusals by what happened (Priority: P2)

Alex wants to hear about any Claude agent that failed for a quota reason, and about any workflow refused because a run of it was still going:

```yaml
on:
  - agent.failed:
      runtime: claude
      reason: [allowance_spent, rate_limited]
  - workflow.refused:
      reason: run_in_flight
```

**Why this priority**: Failures are what people most want to hear about, and today the reasons can't be filtered in practice. This comes after the P1 stories because it changes the values of details that already exist.

**Independent Test**:
- On a scratch root, end agents with each reason and refuse a workflow in each way that is raised.
- The events carry the codes, the triggers fire on the codes, and the Events page still shows the words.

**Acceptance Scenarios**:

1. **Given** the `agent.failed` trigger above, **when** a Claude agent's allowance runs out mid-turn, **then** the workflow runs; **when** a Codex agent's does, **then** it does not.
2. **Given** an existing workflow file with `reason: "its allowance ran out"` (today's words), **when** this version reads it, **then** it fires exactly where it did before. The page shows it as `reason: allowance_spent`.
3. **Given** an agent waiting, from before the update, on `agent.stopped` with `by: "stopped by you"`, **when** the person stops the agent after the update, **then** the wait matches.
4. **Given** a filter value in today's words that no code matches, such as an old `workflow.refused` reason quoting a file's own error, **then** the file's problem says which codes `reason` takes. The trigger doesn't silently never match.
5. **Given** any of these events on the Events page, **then** its sentence reads as it does today. Only the detail's value is a code.

---

### User Story 4 - A mistyped value is named, not silently never matched (Priority: P2)

Alex writes `outcome: complete`.

**Why this priority**: Today this is the commonest way a trigger silently never fires. It costs little once the catalogue knows each detail's values.

**Independent Test**: Write a trigger, and make a wait, with a wrong value on each detail that has a fixed set of values. Each is refused with a sentence that lists the right values.

**Acceptance Scenarios**:

1. **Given** `outcome: complete` in a workflow file, **then** the workflow's page says: *outcome on agent.finished is one of done, nothing_to_do, needs_answer, partly_done, stuck, blocked; "complete" is not one of them.* The workflow doesn't run.
2. **Given** the same filter in a wait, **then** the wait is refused with the same sentence.
3. **Given** a list with one wrong value, such as `outcome: [done, finished]`, **then** the sentence names `finished`.
4. **Given** a detail whose values are open, such as `labels`, `workflow`, `branch` or any detail on a `custom.` event, **then** any value is accepted.
5. **Given** `agent.*` with a filter on a detail only some agent events carry, such as `outcome`, **then** it is accepted as today. Events that don't carry it don't match.

---

### User Story 5 - Read the narrowed trigger in plain words everywhere (Priority: P3)

Alex opens the workflow from User Story 1 on the Mac, on the phone and on the web page, and sees what it listens for in words, not only in YAML. Copy as trigger on an Events row gives a trigger that fires for events like it, not only for that one agent.

**Why this priority**: The trigger works without this. But a filter the page can't say is a filter nobody trusts, and #98's Triggers section exists to say exactly this.

**Independent Test**:
- Open the User Story 1 and 2 workflows on the Mac page, the Triggers section, the web page and the phone.
- Copy as trigger from an `agent.finished` row.

**Acceptance Scenarios**:

1. **Given** the User Story 1 trigger, **then** the project page and the workflow page say: *When an agent in this project ended a turn having done its work (labelled bug, and parked)*.
2. **Given** `outcome: [done, nothing_to_do]`, **then** the summary says *done or nothing to do*. The Triggers section shows the capsule `outcome: done | nothing_to_do`, and the status line and the run's cause say `agent.finished outcome done|nothing_to_do`.
3. **Given** the web page, **then** it shows the same filters as the Mac's Triggers section, lists included.
4. **Given** an older phone that can't read a list, **then** it shows the trigger without that filter, as it shows any trigger it doesn't fully understand. The workflow's firing is unaffected, because firing is the host's.
5. **Given** Copy as trigger on an `agent.finished` row with outcome `done`, labels `bug` and runtime `claude`, **then** it copies `agent.finished` with `outcome: done` and nothing else. It copies neither `agent` nor the agent's labels, runtime or starter.
6. **Given** Copy as trigger on a `custom.` row, **then** it copies the publisher's details as today.

### Edge Cases

- **An agent with no labels**: the event's `labels` is empty. A filter on `labels` never matches it.
- **A label written differently**: `labels: Bug` and an agent labelled `bug` match, compared the way labels are already compared for sameness.
- **Labels with spaces**: a label can contain spaces, though not commas, so `labels: "needs review"` matches the label `needs review`.
- **`started_by` precedence**: an agent started by a workflow's agent, as its helper, is `started_by: agent`, not `workflow`. Only the agent a workflow itself started is `workflow`. An agent started from the phone, the web page or the Mac is `person`.
- **`afterwards` and a pick-up after a restart**: an agent whose turn ending is about to be picked up after a daemon restart raises no `agent.finished` (as today), so it has no `afterwards`.
- **`afterwards` and archiving**: `afterwards` is never `archive`. An agent can't archive itself, and an archive is its own event, `agent.archived`, which carries the agent's last outcome.
- **`agent.stopped` with no reason recorded**: `by: unknown`.
- **An agent stopped by the agent that started it**: today this raises `agent.failed`, with that reason as words. It stays `agent.failed`, with `reason: stopped_by_agent`. Moving it to `agent.stopped` is not part of this.
- **`workflow.completed` for a run with no agent, or whose agent made no report**: no `outcome`. A filter on `outcome` doesn't match it.
- **A custom event published with a detail called `labels` or `runtime`**: unaffected. Custom events carry only their publisher's details, as today.
- **A stored wait or trigger cause from before the update**: it is read and matched with the same meaning (User Story 3, scenario 3).
- **A record written by this version, read by the previous version** (a downgrade): a pattern holding a list must not stop the older version reading the rest of that record. It may read the list as a filter that never matches, or as no filter, but not as unreadable.

## Requirements *(mandatory)*

### Functional Requirements

**Details the events carry**

- **FR-001**: Every `agent.*` event, and `cost.limit_reached` when it is about an agent, MUST carry three more details, describing the agent at the moment of the event:
  - `labels`: the agent's labels.
  - `runtime`: the agent's runtime id.
  - `started_by`: `person`, `workflow` or `agent`.
- **FR-002**: `labels` MUST be a **set** detail. A filter value on it means the agent has that label, and a list means it has at least one of them. Labels MUST be compared the way the app already compares labels for sameness.
- **FR-003**: `agent.finished` MUST carry `afterwards`: `park` when this ending parks the agent (its own ask, or the person's park while the turn ran), and `stay` otherwise.
- **FR-004**: `workflow.completed` MUST carry `outcome`: the outcome of the run's agent's report, when there is one.
- **FR-005**: `agent.parked` and `agent.archived` MUST carry `outcome`: the agent's last report's outcome, when there is one.
- **FR-006**: These details MUST be values you can filter on: listed in the catalogue, in the wait tool's list and in the workflow tool's description, from the one description they already share. The catalogue MAY say once that every agent event carries `labels`, `runtime` and `started_by`, instead of repeating them on every line.

**Codes instead of sentences**

- **FR-007**: `agent.failed`'s `reason` MUST be the ending's code: `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `max_turn_requests`, `refusal`, `daemon_gone`, `stopped_by_agent` or `unrecognised`.
- **FR-008**: `agent.stopped`'s `by` MUST be `you` (stopped by the person), `cost_limit`, or `unknown` (no reason recorded).
- **FR-009**: `agent.archived`'s `by` MUST be `you` or `agent`.
- **FR-010**: `workflow.refused`'s `reason` MUST be the refusal's code: `run_in_flight`, `chain_too_deep`, `archived`, `over_limit`, `unreadable`, `trigger_not_supported`, `agent_unavailable`, `no_triggering_agent`, `missed_while_closed`, `folder_gone`, `day_limit_reached`, `setting_refused` or `awaiting_approval`.
- **FR-011**: Each of these events' sentence, which the Events page, the log and a woken agent read, MUST keep today's words.
- **FR-012**: A filter value in today's words MUST be read as the code it stands for, wherever a pattern is read: a workflow file, the wait tool, a stored wait, a stored run cause, and the wire. Some of today's words vary (a chain's depth, a limit's message); these MUST map by the fixed part of their wording.
- **FR-013**: A value in today's words that maps to no code MUST be a problem that lists the codes (User Story 3, scenario 4), never a filter that silently never matches.

**Any of**

- **FR-014**: A filter value MUST be either one value or a list of values. A list matches when the event's detail equals any of them; on a set detail, when the set holds any of them. A list of one MUST mean exactly the single value.
- **FR-015**: A workflow file MUST accept a list under an event's detail, inline (`[a, b]`) or as a block, as it already does for `days:`.
- **FR-016**: The wait tool's `where` MUST accept, for each key, text, a number, a true/false, or a list of those. Anything else MUST refuse the wait with a sentence saying what a value can be. A value MUST NOT be silently dropped.
- **FR-017**: Workflow triggers and waits MUST keep deciding through the one matcher.

**Values are checked**

- **FR-018**: The catalogue MUST say, for each detail with a fixed set of values, what those values are. This covers at least:
  - `outcome`, `afterwards`, `started_by` and `runtime` (the runtimes this version knows)
  - `agent.failed reason`, `agent.stopped by`, `agent.archived by` and `workflow.refused reason`
  - `agent.retired because` (`age`, `cap`, `person`)
  - `lease.released how`
  - `person.away why` and `person.back why`
  - `cost.allowance_back how`
- **FR-019**: A filter value outside a detail's fixed set MUST be refused, in a workflow file and in a wait, with one sentence naming the detail, the event, the valid values and the value given. For a list, the sentence MUST name the first wrong value.
- **FR-020**: Details whose values are open MUST accept any value. These include `labels`, `agent`, `workflow`, `branch`, `from`, `to`, `resource`, `server`, `limit`, `waiting_on`, `until`, `retry_after` and every detail of a `custom.` event.
- **FR-021**: Under `subject.*`, a value MUST be checked against the union of that detail's values across the subject's events.

**Words**

- **FR-022**: A trigger's summary, on the project page, the workflow page, the web page and the phone, MUST say each filter in words:
  - labels: "labelled bug", "labelled bug or regression"
  - runtime: "on Claude"
  - outcome: "done or nothing to do"
  - `afterwards: park`: "and parked"; `afterwards: stay`: "and not parked"
  - started_by: "started by a workflow", "started by another agent", "started by you"
  - codes: their existing words
  - any other detail: today's "key value"
- **FR-023**: The Triggers section's capsules, the status line, a wait's label and a run's cause MUST show a list as its values joined by `|`, for example `outcome: done | nothing_to_do`.
- **FR-024**: The trigger text a pattern writes back, for example when the page rewrites a file, MUST write a list as an inline list, and MUST read back as the same pattern.
- **FR-025**: Copy as trigger MUST copy an event's own details, and leave out `agent` and the agent details added by FR-001. A `custom.` event's details MUST still all be copied.
- **FR-026**: The web page's trigger words and the Mac's MUST say the same filters, including lists.

**Compatibility**

- **FR-027**: Every workflow file valid today MUST parse to a pattern that matches exactly the events it matched before. The only differences allowed are FR-012's mapping of old words to codes, and FR-013's problem for old words that map to nothing.
- **FR-028**: A pattern with only single values MUST be stored and sent exactly as today, so that the previous version and older phones read it unchanged.
- **FR-029**: A pattern with a list MUST NOT make a record unreadable to the previous version (Edge Cases, downgrade).
- **FR-030**: The old hyphenated trigger names keep taking no filters, and keep firing as today.

### Key Entities

- **Event pattern**: an event name, or `subject.*`, plus filters. Each filter is a detail key and one or more values. It is what a wait and a workflow trigger are both made of.
- **Detail description**: one entry per detail in the catalogue. It holds the key, whether it is a set, its fixed values if it has them, and the words the summary uses for it.
- **Agent context**: the labels, runtime and starter of an agent at the moment of an event about it. It rides on the event's details.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: These 9 test triggers from the research doc can each be written as one trigger, and each fires on a matching event and not on a near miss:
  - T1: finished, labelled `bug`, parked
  - T2: Claude failed for a quota reason
  - T4: finished `done` or `nothing_to_do`
  - T6: a workflow's agent failed
  - T9: nightly completed `stuck` or `partly_done`
  - T10: archived by you, labelled `bug` or `regression`
  - T12: the simulator lease expired
  - T14 without its "except": Gemini or Grok failed
  - W1: a wait for a `deploy`-labelled finish
- **SC-002**: No filter, in a file, a wait or on the wire, is ever dropped without a word. Every value the readers can't take is refused with a sentence.
- **SC-003**: Every workflow file in the repository's tests and examples parses to a pattern matching the same events as before.
- **SC-004**: Every refusal of a bad key or a bad value names the valid keys or values in the same sentence.
- **SC-005**: For every trigger in SC-001, the Mac's project page, the Triggers section and the web page say its filters in words, with no YAML needed to read them.

## Docs *(mandatory)*

- `docs/reference/events.md` — change:
  - add `labels`, `runtime` and `started_by` to the Agents section's opening line, and `afterwards` to `agent.finished`
  - add the missing `agent.parked` and `agent.archived` rows (from #96), with `outcome`
  - add `outcome` to `workflow.completed`
  - list the codes for `agent.failed reason`, `agent.stopped by` and `workflow.refused reason`
  - in "Names and filters", explain lists, set details, and that a wrong value is an error naming the right ones
- `docs/reference/workflows.md` — change: the `on:` event row says a detail can take a list (any of), with an example under it.
- `docs/how-to/wait-for-something.md` — change: `where` takes a list, with the `deploy` label example.
- `docs/how-to/set-up-a-workflow.md` — change: add the "finished, labelled `bug`, parked" example.
- `docs/reference/agent-tools.md` — change: the `wait_for_event` entry, if it describes `where`.

## Assumptions

- **Not in step 1**:
  - negation (`!`) and globs (`*`)
  - `model`, `branch`, `worktree` and `workflow` as agent context
  - `by` on `agent.parked`
  - `agent` on `lease.released` and agent context on `lease.granted`
  - `agent.labelled`
  - an all-of form for labels
  - hearing another project's events
- **No values are reserved in step 1.** A value starting with `!` or holding `*` is matched literally, as today. Step 2's spec owns what happens to such values on open details.
- **`afterwards` is final at the ending.** The daemon decides an ending's parking before it raises `agent.finished`, so the value is known, not guessed.
- **Events stay on their host.** No `host` detail is added: every event a workflow or wait hears is already from its own host.
- **Labels are the agent's labels**, person-owned and agent-owned alike. Which owner added a label doesn't matter to a filter.
- **The known runtimes for FR-018 are this version's.** A file naming a runtime only a later version knows is a problem on this version, as `runtime:` already is.
- **The web page ships with its host**, so it changes with the host. Phones and iPads may be older, and FR-028 and FR-029 cover them.
