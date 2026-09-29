# Feature Specification: Read Another Session's History

**Feature Branch**: `agents/065-continue-successor`

**Created**: 2026-09-26

**Revised**: 2026-09-28, to keep runtime tracking (see Clarifications)

**Status**: Draft

**Input**: User description: "No. Actually want to remove the continue the chat feature. We can also remove the pool feature. Continue noting that an agent ran out of credit. Instead, provide a way for an agent to interrogate another session's history. The intention of this is to allow the user to ask an agent 'please continue the work of session X'."

**Direction confirmed 2026-09-28**: "We're getting rid of the pool, but we're going to track the agents' runtimes better. The read_session tool will allow the user to create a new session from the session that has run out of allowance, rather than trying to continue with a broken session."

## Why this feature exists

When a plan runs out, or when the next part of the work belongs on another runtime, the person
already knows what to do: start a conversation and say what they want. What they cannot do today
is point that conversation at one they already had. They restate the work, or they paste.

The app tried to do that pointing for them. A **pool** of runtimes took a chat over when its
allowance ran out, and **Continue with** moved a chat by hand. Both rewrote the same conversation
underneath, so one session became two runtimes. That is the complexity to take out.

Two things stay. The chat ends honestly: this chat ran out of credit. And the app keeps knowing
each runtime's state: which one is out, since when, when it is next checked, and what is left of
its plan. That knowledge was built for the pool. It now serves the person picking a runtime for
the next chat.

What goes in is a way for an agent to **read another session's history** in the same project.
The person starts a new chat, on whichever runtime they want, and says "please continue the work
of session X." The agent looks that session up, reads what was said and done, and carries on. The
original is untouched.

## Clarifications

### Session 2026-09-26

- Q: When a runtime's allowance runs out, does a successor start by itself? → A: No. The chat
  stops. Nothing continues it.
- Q: Does the person continue a chat with **Continue with**, as a new conversation? → A: No.
  **Continue with** is removed. So is the pool.
- Q: How does the work go on? → A: The person asks an agent to continue the work of a named
  session. That agent can read the named session's history.

### Session 2026-09-28

- Q: The pool is going. Does the app still track whether each runtime is out? → A: Yes. The
  per-runtime state (out, since when, the four-hour availability check, the provider's reset
  time, what is left of the plan) stays. It moves from the Pool page to **Settings ▸ Agent
  Runtimes**. It now covers every runtime the person has set up, not only those in a pool.
  This replaces the 2026-09-26 answer that a refusal is only a fact about that turn.
- Q: Does "user (or system)" mean the app may start a successor? → A: No. When a chat runs out,
  it stops with its note. The person starts the next chat and names the one to continue.
- Q: Does a runtime marked out stop other chats from using it? → A: No. It is shown and warned
  about, never enforced. A new chat on an out runtime says so before its first message is
  sent, as today. The person can send anyway. A chat already on that runtime is prompted as
  usual. If its turn works, the runtime is back.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ask an agent to continue another session (Priority: P1)

The person had a chat titled **Login redirect** on Claude. Claude's allowance ran out, or they
simply want Codex to take the next part. They start a new chat on Codex and type: "Please
continue the work of Login redirect."

The agent finds that session in this project, reads its history — what was asked, what it said,
what it did, the plan as it stood — and carries on from there. The files on disk are already as
that session left them. **Login redirect** is unchanged: same runtime, same history, same place
in the list.

If two sessions share that title, the agent is told so and shown the matches, and the person
says which. If nothing in the project has that name, the agent is told, and can list the
sessions that are there.

**Why this priority**: It is the feature. The person already knows how to start a chat; they
need the agent to see the other one.

**Independent Test**: In a project with a finished chat titled something unique, start a second
chat and ask it to continue that work by name. Check it can recount what the first chat did and
then do the next step, and that the first chat is untouched.

**Acceptance Scenarios**:

1. **Given** a project with a session titled "Login redirect", **When** the person starts a new
   chat and asks it to continue that work, **Then** the new agent can read that session's
   history and act on it.
2. **Given** that read, **When** the original session is opened, **Then** it is unchanged: same
   runtime, same history, same status.
3. **Given** no session in the project with that name, **When** the agent looks it up, **Then**
   it is told there is no such session, and can list the sessions in the project by title.
4. **Given** two sessions with the same title, **When** the agent looks that title up, **Then**
   it is told the name is used more than once, with enough on each (when, runtime, status) to
   tell them apart.
5. **Given** a session that has been retired, **When** the agent looks it up, **Then** it is
   told the conversation is gone.

---

### User Story 2 - A spent allowance stops the chat and says so (Priority: P1)

An agent is in the middle of a job when its runtime's allowance runs out. The turn ends. The
chat stays on that runtime. A note in the conversation says the allowance ran out, and until
when if the runtime said. The status is **Its allowance ran out**.

The chat is not continued. No other runtime is started. The chat does not wait to carry on.
There is no **Continue with**, no Pool page, no pool in Settings, no Matching models.

The app does note that the runtime is out. **Settings ▸ Agent Runtimes** shows it as out, with
when it is next checked. A new chat about to start on it says so before its first message.

The person can start a new chat and ask it to continue this one, as in Story 1. If they never
do, this chat stays where it ended.

**Why this priority**: The pool and Continue with are what made sessions a mixture of runtimes.
The note and the runtime's state are the useful part of that work.

**Independent Test**: Make a chat's runtime refuse a turn with its recognised allowance
message. Check the chat stays on that runtime with the ran-out note and status, that no second
conversation started, that the runtime shows as out in Agent Runtimes, and that Pool and
Continue with are gone from the app.

**Acceptance Scenarios**:

1. **Given** a chat whose runtime's allowance is spent, **When** the turn ends, **Then** the
   chat is still on that runtime, stopped, with a note that the allowance ran out (and until
   when, if known).
2. **Given** that ending, **When** the list is read, **Then** the chat is under Paused as **Its
   allowance ran out**.
3. **Given** that chat, **When** time passes or the allowance comes back, **Then** no other
   conversation is started for it, and it is not resumed.
4. **Given** a rate limit rather than a spent allowance, **When** the turn is refused, **Then**
   the chat stays on that runtime and is tried again there after a short wait, as today.
5. **Given** the Mac, iPhone or iPad, **When** the person looks for a Pool page, a pool in
   Settings, Continue with, or Matching models, **Then** none of them is there.
6. **Given** a runtime that is out, **When** another chat on it is prompted, **Then** the
   prompt is sent as usual. It is not blocked and does not wait. If it is refused the same
   way, that chat gets its own note.
7. **Given** a turn that reports exhausted credit or starts paid extra usage, **When** the
   runtime reports it, **Then** the current chat records the matching note and does not move to
   another runtime; a completed turn remains completed, and a failed turn ends as **Its
   allowance ran out**.

---

### User Story 3 - Read what a session actually did (Priority: P2)

The history an agent gets is the app's own record of that session: the person's messages, the
agent's replies, the tools it ran (with the file when there was one), and the plan as it last
stood. It is not the other runtime's private notes.

A long session is shortened to fit: the first request and the latest turns are kept, the middle
is dropped, and the history says how many turns were left out. A short session is given whole.

**Why this priority**: A continuation that cannot see what was done will redo it or miss it. The
shortening is what makes a long chat usable on a smaller context.

**Independent Test**: Ask an agent to read a short session and check the first request, a later
reply, a tool it ran, and the plan are all there. Ask it to read a session longer than will fit,
and check the first request and the latest turns are there and the omitted count is stated.

**Acceptance Scenarios**:

1. **Given** a session that asked for a change, made it, and left a plan, **When** another agent
   reads it, **Then** the history includes that request, that it edited the file, and the plan.
2. **Given** a session whose history is too long to give whole, **When** it is read, **Then** the
   first request and the latest turns are present, and the history says how many turns were
   left out.
3. **Given** a session that is still working, **When** it is read, **Then** the history is what
   has been recorded so far.
4. **Given** an archived session whose conversation is still kept, **When** it is read, **Then**
   the history is given. A retired session is Story 1, scenario 5.

---

### User Story 4 - See each runtime's state where runtimes are set up (Priority: P2)

The person opens **Settings ▸ Agent Runtimes** to choose where the next chat should run. Each
runtime says whether it is available, rate limited or out. An out runtime says since when, the
provider's reset time if it gave one, and when the app next checks it. Where the runtime reports
it, the row shows what is left of its plan: **28% left this week · resets Sun 20:39 · as of
14:02**. **Mark available** is on any runtime that is out.

This is the Pool page's state, without the pool. Every runtime the person has set up is tracked,
not only those that were in a pool.

**Why this priority**: The person now picks the runtime for the next chat. Without the state,
they cannot tell which one will work.

**Independent Test**: Mark one runtime out through a recognised refusal. Check that Agent
Runtimes shows it out with its next check, that a passing check brings it back, and that
another runtime's plan reading is shown on its row.

**Acceptance Scenarios**:

1. **Given** a runtime whose allowance was spent in any chat, **When** Agent Runtimes is
   opened, **Then** that runtime is shown as out, with since when and when it is next checked.
2. **Given** an out runtime, **When** four hours have passed since it went out, **Then** the app
   runs a short read-only check on a small model, as today, and a pass brings it back. A failed
   check leaves it out and schedules the next one four hours later.
3. **Given** an out runtime, **When** a turn on it works in any chat, **Then** it is shown as
   available again.
4. **Given** an out runtime, **When** the person chooses **Mark available**, **Then** it is shown
   as available.
5. **Given** a runtime that crashes or fails with an error the app does not recognise, **When**
   the turn ends, **Then** that runtime is shown as out, and checked as above.
6. **Given** a new chat whose runtime is out, **When** the person is about to send its first
   message, **Then** the prompt bar says the runtime is out, and until when if known. The
   person can still send.
7. **Given** the iPhone or iPad, **When** the person looks at a runtime's settings, **Then** the
   same state is shown there.

---

### Edge Cases

- Looking up a session in another project is refused: only this project.
- Looking up this agent's own session is allowed and returns its history so far.
- An id from `start_agent` or from the list is accepted, as well as an exact title.
- A helper another agent started can read sessions in the project the same way. It cannot start
  agents of its own, as today.
- An empty project lists no sessions besides the caller, or only the caller.
- Removing the pool does not bring back pay-as-you-go carrying-on: a spent allowance still ends
  the chat. Cost limits (per agent and per day) are unchanged.
- A runtime that was out in the pool before this change is still out after it, with its next
  check kept.
- A chat that was waiting for an allowance when the app updates stops waiting. It is not
  started again.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: An agent MUST be able to list the sessions in its own project: each one's title,
  id, runtime, status, and what it last said, when it has said something. Sessions MUST be
  ordered by most recent activity first.
- **FR-002**: An agent MUST be able to read one session's history by id or by exact title. The
  history is the app's record of that session: the person's messages, the agent's replies, the
  tools it ran, and the plan as it stood.
- **FR-003**: Reading a session MUST NOT change that session.
- **FR-004**: A title that matches no session MUST be refused with a sentence that says so. A
  title that matches more than one MUST be refused with a sentence that lists the matches. An
  id that is not a session in this project MUST be refused the same way.
- **FR-005**: A retired session MUST be refused: its conversation is gone. An archived session
  that is still kept MUST be readable.
- **FR-006**: A rendered history over 80,000 characters MUST keep the first request and as many
  of the latest complete turns as fit, always include the last recorded plan, and say how many
  turns were left out. A history at or below that limit MUST be returned whole.
- **FR-007**: These tools are given to every agent in the project, including one another agent
  started. They are not given a way to read another project.
- **FR-008**: The person is not asked before a list or a read. The sessions are theirs.
- **FR-009**: A spent allowance MUST end the chat on its runtime, with a note that the
  allowance ran out (and until when, if the runtime said) and with status **Its allowance ran
  out**. The app MUST NOT start another conversation, MUST NOT move the chat to another
  runtime, and MUST NOT wait to carry it on.
- **FR-009a**: Exhausted credit MUST end only the refused chat on its current runtime with the
  credit-used-up note and status **Its allowance ran out**. When a runtime reports that paid
  extra usage has begun, the app MUST record that fact on the current chat and MUST NOT move it
  or start another conversation. If that same turn completed, its completed outcome MUST be
  preserved; if it failed, it MUST end as **Its allowance ran out**.
- **FR-010**: **Continue with**, the pool (the Pool page, the pool in Settings, the pool's order,
  Matching models, waiting for an allowance, carrying on by itself, the switch history) MUST be
  gone from the Mac, iPhone and iPad.
- **FR-011**: A rate limit MUST still be retried on the same chat's next attempt, on that
  runtime. That wait is for this turn only.
- **FR-012**: The app MUST keep each runtime's state: available, rate limited or out, with the
  reason, since when, the provider's reset time if given, and when it is next checked. A spent
  allowance, exhausted credit, or a crash or unrecognised failure in any chat MUST mark that
  runtime out. A turn that works on it, a passing availability check, or **Mark available**
  MUST mark it available. This MUST cover every runtime the person has set up, with no pool
  to turn on.
- **FR-012a**: Availability checks MUST keep working as they do today: a short read-only
  conversation on a small model, run once four hours have passed since the runtime went out or
  since its last failed check. A provider's reset time MUST be shown but MUST NOT by itself mark
  a runtime available.
- **FR-012b**: An out runtime MUST NOT be enforced. The app MUST NOT refuse, hold or delay a
  prompt to a runtime because it is marked out. A new chat about to start on an out runtime
  MUST say so before its first message, and MUST let the person send anyway.
- **FR-013**: The runtime's state, what is left of its plan when the runtime reports it, and
  **Mark available** MUST be shown in **Settings ▸ Agent Runtimes** on the Mac, and in the
  runtime's settings on the iPhone and iPad.
- **FR-014**: The events that say a runtime went out or came back (`cost.allowance_out`,
  `cost.allowance_back`) MUST still be sent. `agent.runtime_switched` MUST be removed.

### Key Entities

- **Session**: One conversation with one runtime in one folder, as the person already knows it.
  It has a title, an id, a runtime, a status, and a history.
- **History**: The app's record of a session, given to another agent as readable text: what was
  asked, what was said, what was done, the plan.
- **Runtime state**: What the app knows about one runtime's allowance: available, rate limited
  or out; why; since when; the provider's reset time; the next check; what is left of the plan.
  It is kept per runtime and credential, and it is shown, not enforced.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person can start a new chat, name an existing session in the project, and have
  that new agent continue the work without restating what already happened.
- **SC-002**: After that, the named session is the same conversation it was: same runtime, same
  history, same place in the list.
- **SC-003**: A chat whose allowance runs out is still on that runtime one hour later, with a
  note that it ran out, and with no second conversation started for it.
- **SC-004**: The person cannot find Continue with, a Pool page, or a pool in Settings.
- **SC-005**: A person choosing a runtime for a new chat can see, in Agent Runtimes, which
  runtimes are out and when each is next checked, without opening any chat.

## Docs *(mandatory)*

- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — replace: a spent allowance stops the
  chat; see which runtimes are out in Agent Runtimes; to go on, start a new chat and ask it to
  continue that session
- `docs/explanation/runtime-pool.md` — remove
- `docs/reference/settings.md` — change: remove the Pool pane; add runtime state, plan left and
  Mark available to Agent Runtimes
- `docs/reference/statuses.md` — change: drop **Waiting for an allowance** and the pool's
  carry-on; keep **Its allowance ran out**
- `docs/reference/events.md` — change: drop `agent.runtime_switched`; keep `cost.allowance_out`
  and `cost.allowance_back`, now about any runtime rather than a pool entry
- `docs/reference/agent-tools.md` — add: listing and reading a session in this project
- `docs/reference/runtimes.md` — change: remove carrying on with the next runtime; keep the
  table of what each runtime reports and when it is checked, without "in the pool"
- `docs/how-to/index.md` — change: drop or retitle the keep-going guide

## Assumptions

- The person starts the new agent themselves, on the runtime they want. This feature does not
  pick a runtime or start a chat for them.
- Listing and reading is enough; there is no picker in the prompt bar that attaches a session.
- Where the other session was working (folder or worktree) is in the history. Moving there is
  the agent's existing worktree tools, when it has them.
- Limit recognition stays on the turn that was refused, so that chat's note is a recognised
  ending rather than a generic refusal. The same recognition also marks the runtime out.
- Free or prepaid credit on an API key (such as a Gemini key), with its amount, expiry and the
  app's count of what it has cost, is a runtime's setting, not the pool's. It moves to Agent
  Runtimes with the state, and a key that is used up or past its date is marked out.
- The prompt bar's out notice no longer offers another runtime "instead" from the pool's order.
  It says the runtime is out and until when.
- Existing pool and allowance files are read once to carry each runtime's state over. The pool's
  order, Matching models and switch history are left on disk and no longer read.
- Per-agent and per-day cost limits are unchanged.
- **Branch** stays a same-runtime copy and is not this feature.
