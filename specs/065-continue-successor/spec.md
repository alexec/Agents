# Feature Specification: Read Another Session's History

**Feature Branch**: `agents/065-continue-successor`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "No. Actually want to remove the continue the chat feature. We can also remove the pool feature. Continue noting that an agent ran out of credit. Instead, provide a way for an agent to interrogate another session's history. The intention of this is to allow the user to ask an agent 'please continue the work of session X'."

**Direction confirmed 2026-09-28**: "We're getting rid of the pool, but we're going to track the agents' runtimes better. The read_session tool will allow the user (or system) to create a new session from the session that has run out of allowance, rather than trying to continue with a broken session."

## Why this feature exists

When a plan runs out, or when the next part of the work belongs on another runtime, the person
already knows what to do: start a conversation and say what they want. What they cannot do today
is point that conversation at one they already had. They restate the work, or they paste.

The app tried to do that pointing for them. A **pool** of runtimes took a chat over when its
allowance ran out, and **Continue with** moved a chat by hand. Both rewrote the same conversation
underneath, so one session became two runtimes. That is the complexity to take out.

What stays is the honest ending: this chat ran out of credit. What goes in is a way for an agent
to **read another session’s history** in the same project. The person starts a new chat, on
whichever runtime they want, and says “please continue the work of session X.” The agent looks
that session up, reads what was said and done, and carries on. The original is untouched.

## Clarifications

### Session 2026-09-26

- Q: When a runtime’s allowance runs out, does a successor start by itself? → A: No. The chat
  stops. Nothing continues it.
- Q: Does the person continue a chat with **Continue with**, as a new conversation? → A: No.
  **Continue with** is removed. So is the pool.
- Q: How does the work go on? → A: The person asks an agent to continue the work of a named
  session. That agent can read the named session’s history.
- Q: After one chat’s allowance is spent, does the app remember that runtime is out for
  other chats? → A: No. A refusal is a fact about that turn. The app does not keep an
  “out until” for the plan, and does not treat other chats on the same runtime as out.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ask an agent to continue another session (Priority: P1)

The person had a chat titled **Login redirect** on Claude. Claude’s allowance ran out, or they
simply want Codex to take the next part. They start a new chat on Codex and type: “Please
continue the work of Login redirect.”

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

1. **Given** a project with a session titled “Login redirect”, **When** the person starts a new
   chat and asks it to continue that work, **Then** the new agent can read that session’s
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

An agent is in the middle of a job when its runtime’s allowance runs out. The turn ends. The
chat stays on that runtime. A note in the conversation says the allowance ran out, and until
when if the runtime said. The status is **Its allowance ran out**.

Nothing else happens. No other runtime is started. The chat does not wait to carry on. There is
no **Continue with**. There is no Pool page, no pool in Settings, no Matching models.

The person can start a new chat and ask it to continue this one, as in Story 1. If they never
do, this chat stays where it ended.

Another chat on the same runtime is ordinary. It is not marked out, it is not prevented from
starting, and it is not told the plan is spent. If that chat is later refused the same way, it
gets its own note.

**Why this priority**: The pool and Continue with are what made sessions a mixture of runtimes.
The note is the useful part of that work.

**Independent Test**: Make a chat’s runtime refuse a turn with its recognised allowance
message. Check the chat stays on that runtime with the ran-out note and status, that no second
conversation started, and that Pool and Continue with are gone from the app.

**Acceptance Scenarios**:

1. **Given** a chat whose runtime’s allowance is spent, **When** the turn ends, **Then** the
   chat is still on that runtime, stopped, with a note that the allowance ran out (and until
   when, if known).
2. **Given** that ending, **When** the list is read, **Then** the chat is under Paused as **Its
   allowance ran out**.
3. **Given** that chat, **When** time passes or the allowance comes back, **Then** no other
   conversation is started for it.
4. **Given** a rate limit rather than a spent allowance, **When** the turn is refused, **Then**
   the chat stays on that runtime and is tried again there after a short wait, as today.
5. **Given** the Mac, iPhone or iPad, **When** the person looks for a Pool page, a pool in
   Settings, Continue with, or Matching models, **Then** none of them is there.
6. **Given** a chat that just ran out, **When** another chat on the same runtime is started or
   prompted, **Then** that chat is not treated as out: no ran-out note, no block, no wait.
7. **Given** a turn that reports exhausted credit or starts paid extra usage, **When** the
   runtime reports it, **Then** the current chat records the matching note and does not move to
   another runtime; a completed turn remains completed, and a failed turn ends as **Its
   allowance ran out**.

---

### User Story 3 - Read what a session actually did (Priority: P2)

The history an agent gets is the app’s own record of that session: the person’s messages, the
agent’s replies, the tools it ran (with the file when there was one), and the plan as it last
stood. It is not the other runtime’s private notes.

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

### Edge Cases

- Looking up a session in another project is refused: only this project.
- Looking up this agent’s own session is allowed and returns its history so far.
- An id from `start_agent` or from the list is accepted, as well as an exact title.
- A helper another agent started can read sessions in the project the same way. It cannot start
  agents of its own, as today.
- An empty project lists no sessions besides the caller, or only the caller.
- Removing the pool does not bring back pay-as-you-go carrying-on: a spent allowance still ends
  the chat. Cost limits (per agent and per day) are unchanged.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: An agent MUST be able to list the sessions in its own project: each one’s title,
  id, runtime, status, and what it last said, when it has said something. Sessions MUST be
  ordered by most recent activity first.
- **FR-002**: An agent MUST be able to read one session’s history by id or by exact title. The
  history is the app’s record of that session: the person’s messages, the agent’s replies, the
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
- **FR-010**: **Continue with**, the pool (Settings, the Pool page, Matching models, waiting
  for an allowance, carrying on by itself) MUST be gone from the Mac, iPhone and iPad.
- **FR-011**: A rate limit MUST still be retried on the same chat’s next attempt, on that
  runtime. That wait is for this turn, not a memory that the runtime is out.
- **FR-012**: The app MUST NOT remember that a runtime or a credential is out, or when it
  comes back, from another chat’s refusal. Only the chat that was refused carries that
  ending. Other chats on the same runtime are started and prompted as usual.

### Key Entities

- **Session**: One conversation with one runtime in one folder, as the person already knows it.
  It has a title, an id, a runtime, a status, and a history.
- **History**: The app’s record of a session, given to another agent as readable text: what was
  asked, what was said, what was done, the plan.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person can start a new chat, name an existing session in the project, and have
  that new agent continue the work without restating what already happened.
- **SC-002**: After that, the named session is the same conversation it was: same runtime, same
  history, same place in the list.
- **SC-003**: A chat whose allowance runs out is still on that runtime one hour later, with a
  note that it ran out, and with no second conversation started for it.
- **SC-004**: The person cannot find Continue with, a Pool page, or a pool in Settings.

## Docs *(mandatory)*

- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — replace: a spent allowance stops the
  chat; to go on, start a new chat and ask it to continue that session
- `docs/explanation/runtime-pool.md` — remove
- `docs/reference/settings.md` — change: remove the Pool pane
- `docs/reference/statuses.md` — change: drop **Waiting for an allowance** and the pool’s
  carry-on; keep **Its allowance ran out**
- `docs/reference/events.md` — change: drop `agent.runtime_switched`, `cost.allowance_out` and `cost.allowance_back`
  (a runtime-wide out is the memory this feature does not keep)
- `docs/reference/agent-tools.md` — add: listing and reading a session in this project
- `docs/reference/runtimes.md` — change: remove carrying on with the next runtime
- `docs/how-to/index.md` — change: drop or retitle the keep-going guide

## Assumptions

- The person starts the new agent themselves, on the runtime they want. This feature does not
  pick a runtime or start a chat for them.
- Listing and reading is enough; there is no picker in the prompt bar that attaches a session.
- Where the other session was working (folder or worktree) is in the history. Moving there is
  the agent’s existing worktree tools, when it has them.
- Limit recognition stays on the turn that was refused, so that chat’s note is a recognised
  ending rather than a generic refusal. It is not stored as a fact about the runtime.
- Per-agent and per-day cost limits are unchanged.
- **Branch** stays a same-runtime copy and is not this feature.
