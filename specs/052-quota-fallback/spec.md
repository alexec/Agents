# Feature Specification: Carry On When a Runtime Runs Out

**Feature Branch**: `agents/052-quota-fallback`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "I'd like to add support for auto-switching agents when we run out of credit. Many agents give you a generous free/cheap allowance, but then try and get you onto usage based cost. No thanks. We can maintain a known pool of agents that might work, when they fail due to quota exhaustion, we can switch the chat automatically to another agent from the pool. Is this feasible?"

## Why this feature exists

Every runtime the app can start (Claude, Codex, Copilot, Cursor, Grok, and those still to come)
comes with an allowance: a subscription window, a monthly quota, some free credit. When it runs
out, the turn fails, and the chat stops. Some runtimes go further and offer to carry on at
pay-as-you-go prices. The person using this app does not want that. They already have several
allowances across several runtimes, and when one is spent they would rather the work went on with
the next one than pay by the token or wait for a reset.

Today, when a runtime runs out, the chat ends with "stopped answering" or a runtime's own error
text, and the person has to notice, start a new chat on another runtime, and explain the work to
it again. Overnight, or with several agents running at once, that means the work simply stops.

This feature lets the person keep a **pool**: an ordered list of runtimes they are happy to use.
When the runtime a chat is on says its allowance is spent, the app marks that runtime as out, moves
the chat to the next runtime in the pool that is not out, hands it the conversation so far, and
sends it the prompt that failed. The chat stays the same chat, in the same folder, with the same
history on the page. The person reads one line saying it moved, and why.

### Is it feasible?

Yes, with two limits the person should know about up front:

- **The app has to recognise the refusal.** Each runtime says "you are out" in its own words, and
  some only in prose. The app already tells a refused sign-in apart from a crash (043); a spent
  allowance is the same kind of recognition, runtime by runtime. A refusal the app does not
  recognise stops the chat as it does today. It never switches on a guess.
- **The new runtime starts a new conversation.** Runtimes cannot take over each other's sessions.
  What the app can do, because it keeps its own copy of every conversation, is hand the new
  runtime that history as its starting context. The new runtime knows what was said and done, and
  the files on disk are as the old runtime left them. It does not have the old runtime's private
  working memory (its cache, its internal notes, its own summary of a long chat).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A chat moves on by itself when its runtime runs out (Priority: P1)

The person has a pool of Claude, then Codex, then Copilot. An agent on Claude is halfway through a
job at 2 a.m. when Claude's usage window is spent. The turn fails with Claude's limit message. The
app records one line in the chat ("Claude's allowance ran out, until 07:00. Carried on with
Codex."), starts Codex in the same folder with the conversation so far, and sends it the prompt
that failed. Codex carries on. In the morning the person reads the chat top to bottom and sees one
conversation with a switch in it, and the work done.

**Why this priority**: It is the feature. Everything else makes it safer, more visible or more
convenient.

**Independent Test**: On a scratch root with a pool of two runtimes, make the first one refuse a
turn with its recognised allowance message (a stand-in runtime is enough). Check that the chat
continues on the second runtime without anyone touching it, that the failed prompt was re-sent
once, that the transcript holds the switch note, and that the new runtime was given the earlier
conversation.

**Acceptance Scenarios**:

1. **Given** a pool of A then B and a chat on A, **When** A refuses a turn because its allowance
   is spent, **Then** the chat moves to B, B is given the conversation so far, the prompt that
   failed is sent to B once, and a note in the chat names both runtimes and the reason.
2. **Given** the same, **When** A fails for any other reason (a crash, a refused sign-in, the
   person's own cost limit, a context-length stop), **Then** the chat does not move and ends as it
   does today.
3. **Given** a chat that has moved to B, **When** the person opens it on the Mac or the phone,
   **Then** the row and the prompt controls show B, and the history above the switch note is
   unchanged.
4. **Given** A offers to continue at pay-as-you-go prices instead of refusing outright, **When**
   the pool is on, **Then** the app declines that offer on the person's behalf and treats A as out.

---

### User Story 2 - Setting up the pool (Priority: P1)

The person opens Settings and finds a list of their installed, signed-in runtimes. They turn on
the ones they are happy to fall back to and drag them into the order they prefer. They can name a
model for an entry where the runtime offers a choice. A runtime that is not installed or not signed
in cannot be added. With fewer than two runtimes in the pool, nothing switches.

**Why this priority**: Without a pool there is nothing to switch to. It ships with Story 1.

**Independent Test**: In Settings, add three runtimes, reorder them, remove one, relaunch the app,
and check the pool is as it was left. Check an uninstalled runtime is offered as not available.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** the person opens Settings, **Then** the pool is empty and
   switching is off.
2. **Given** a pool of three, **When** the person reorders it, **Then** the next switch follows the
   new order.
3. **Given** a runtime in the pool is later signed out or uninstalled, **When** a switch would pick
   it, **Then** it is skipped and the next one is tried.

---

### User Story 3 - Seeing which runtimes are out, and until when (Priority: P2)

After a switch, the person wants to know what state their allowances are in. The pool in Settings
shows each runtime as available or out, with the time it is expected back when the runtime said
so. New chats started on a runtime that is out warn before the first prompt and offer the first
available one instead. The person can mark a runtime as available again by hand, for when they
know better (they bought more credit, a new month began).

**Why this priority**: Without it, every other chat hits the same wall one at a time, and the
person cannot tell why things moved.

**Independent Test**: Make a runtime report out with a reset time; check Settings shows it out
until then, check a new chat on it warns, clear it by hand, check the warning is gone.

**Acceptance Scenarios**:

1. **Given** A ran out with a stated reset time, **When** that time passes, **Then** A is shown as
   available again without the person doing anything.
2. **Given** A ran out without a stated reset time, **When** the person looks at the pool,
   **Then** A shows as out since the time it ran out, and is tried again no sooner than one hour
   later.
3. **Given** several chats on A, **When** A runs out in one of them, **Then** the others move the
   next time they would send A a turn, without first failing on A themselves.

---

### User Story 4 - Everyone out: wait, then carry on (Priority: P2)

Every runtime in the pool is out. The chat stops with a note that says so and when the earliest
allowance comes back. If a reset time is known, the chat waits and resumes by itself on that
runtime when it comes back, the same way a blocked agent is checked on again later (039).

**Why this priority**: Overnight runs are the main reason to want this feature. A chat that stops
for good at 3 a.m. when an allowance returns at 5 a.m. loses most of the value.

**Independent Test**: Pool of two, both made to report out with reset times a few minutes ahead;
check the chat stops with the note, then resumes on the one that comes back first.

**Acceptance Scenarios**:

1. **Given** every runtime in the pool is out, **When** the chat's turn fails, **Then** it stops
   with a note naming the earliest known return time, and its status reads as waiting, not failed.
2. **Given** that wait, **When** the earliest runtime comes back, **Then** the chat resumes on it
   with the failed prompt.
3. **Given** that wait, **When** the person sends a prompt or stops the chat, **Then** the
   automatic resume is dropped.

---

### User Story 5 - Moving a chat by hand (Priority: P3)

The person wants to move a chat to another runtime themselves: to save one allowance for later, or
because another runtime is better at this kind of task. They pick "Continue with…" on the chat and
choose a runtime. The chat moves the same way as an automatic switch, without re-sending anything.

**Why this priority**: It reuses the whole of Story 1 and is useful on its own, but nobody is
blocked without it.

**Independent Test**: On an idle chat, choose Continue with another runtime; check the note, the
new runtime in the controls, and that the next prompt goes to it with the history.

**Acceptance Scenarios**:

1. **Given** an idle chat on A, **When** the person continues it with B, **Then** the chat is on B
   and its next prompt goes to B with the conversation so far.
2. **Given** a chat with a turn in flight, **When** the person picks Continue with, **Then** they
   are asked to stop the turn first.

### Edge Cases

- **Partway through a turn.** A runtime can run out after it has already edited files. The new
  runtime is given everything the transcript holds, including the tool calls and edits made so
  far, and the prompt again; it is not told the work was undone, because it was not.
- **Unrecognised refusal.** A runtime that changes its wording, or a new runtime, fails as today.
  The raw error is kept in the log so its wording can be added.
- **A misrecognised refusal** (the app switches when the runtime was not actually out). The
  person can mark the runtime available again and continue the chat back on it by hand (Story 3,
  Story 5).
- **Flapping.** A chat never switches more than once for the same prompt without a reply in
  between from some runtime; if the runtime it moved to fails with an allowance refusal on its very
  first turn, it moves on down the pool, but never back to one already tried for that prompt.
- **A chat started on a runtime not in the pool.** It is still switched, to the first available
  pool runtime, if the pool is on. The person can turn switching off for one chat.
- **Long conversations.** A history larger than the new runtime can take is shortened for the
  handoff, oldest first, keeping the original request and the most recent turns; the note says it
  was shortened.
- **Questions and permission prompts open when the runtime runs out** are closed as unanswered,
  as they are when a runtime goes away today, and the new runtime asks again if it needs to.
- **Agents started by agents, and workflow-started agents,** use the same pool as any other chat.
- **Chats on a Linux server (037)** can only switch to runtimes installed and signed in on that
  server; the pool is filtered by what that host has.
- **Worktrees.** The chat keeps its worktree and branch; the new runtime works in the same place.
- **Cost limits (010).** A chat's spending keeps adding up across runtimes. A cost limit the person
  set is never a reason to switch.
- **Different options.** Mode and model do not map one to one between runtimes. The new runtime
  starts in the closest mode to the one the chat was in and in the model named on the pool entry,
  else the runtime's default; never in a looser mode than the chat had.

## Requirements *(mandatory)*

### Functional Requirements

**Pool**

- **FR-001**: The person MUST be able to keep one ordered pool of runtimes, each optionally with a
  model, and add, remove and reorder its entries in Settings.
- **FR-002**: Only installed, signed-in runtimes MUST be addable; entries that stop being usable
  MUST stay in the pool, shown as unavailable, and be skipped.
- **FR-003**: Switching MUST be off until the pool holds at least two runtimes, and the person
  MUST be able to turn it off for the whole app or for one chat.
- **FR-004**: The pool MUST survive restarts of the app and the daemon.

**Recognising a spent allowance**

- **FR-005**: The app MUST tell a spent allowance apart from every other way a turn ends, for each
  runtime it knows, and MUST record which one it was.
- **FR-006**: The app MUST NOT switch on any ending it does not positively recognise as a spent
  allowance, including crashes, refused sign-ins, the person's cost limits and context limits.
- **FR-007**: When a runtime offers to continue at usage-based prices, the app MUST decline the
  offer and treat the runtime as out. It MUST never accept such an offer on the person's behalf.
- **FR-008**: The app MUST keep, per runtime, whether it is out, since when, and until when if the
  runtime said; a runtime with no stated return MUST be tried again no sooner than one hour after it
  ran out. The person MUST be able to mark a runtime available again.

**Switching**

- **FR-009**: When a chat's runtime is recognised as out, the app MUST move the chat to the first
  runtime in the pool order that is usable and not out, skipping any already tried for the same
  prompt.
- **FR-010**: The chat MUST remain the same chat: same identity, title, project, folder, worktree,
  history, attachments, queued prompts and spending.
- **FR-011**: The new runtime MUST be given the conversation so far as its starting context, and
  the prompt that failed MUST be sent to it exactly once.
- **FR-012**: A chat MUST NOT start a turn on a runtime that is currently out; it moves first.
- **FR-013**: Every switch MUST leave one note in the chat naming the old runtime, the new one, the
  reason, and the old runtime's expected return time if known.
- **FR-014**: Every switch MUST be published as an event other agents and workflows can wait on
  (042), carrying the chat, both runtimes and the reason.
- **FR-015**: The new runtime MUST start in a mode no looser than the chat's current mode, and in
  the pool entry's model or else the runtime's default.

**Everyone out**

- **FR-016**: When no runtime in the pool is usable, the chat MUST stop with a note naming the
  earliest known return, and MUST resume on its own on the first runtime to come back when a return
  time is known.
- **FR-017**: A prompt from the person, or stopping, parking or archiving the chat, MUST cancel
  that automatic resume.

**By hand**

- **FR-018**: The person MUST be able to continue an idle chat with any usable runtime, from the
  Mac and from the phone, with the same carry-over as an automatic switch and nothing re-sent.

### Key Entities

- **Pool**: the person's ordered list of acceptable runtimes; each entry is a runtime and an
  optional model. App-wide.
- **Runtime allowance state**: per runtime (and per host, for servers), available or out; when it
  ran out; when it is expected back, if known; how the app learned it.
- **Switch**: one move of one chat from one runtime to another: when, from, to, why (spent
  allowance, everyone out then resumed, or by hand), and the prompt it carried.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With two or more usable runtimes in the pool, a chat whose runtime runs out carries
  on with the next one within 30 seconds, with nobody touching anything.
- **SC-002**: No chat ever runs at usage-based prices because of this feature: across all tests,
  zero pay-as-you-go offers accepted.
- **SC-003**: Zero switches caused by endings that were not a spent allowance, across a test set
  that includes every other kind of ending the app knows.
- **SC-004**: After a switch, the new runtime can answer a question about something decided
  before the switch, in 9 of 10 tries on the test conversations.
- **SC-005**: For every runtime in the catalogue at release, its spent-allowance refusal is
  recognised, or the docs say plainly that it is not yet.
- **SC-006**: A person reading a switched chat can say which runtime answered each turn and why it
  changed, from the chat alone.

## Docs *(mandatory)*

- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — add: setting up the pool, what a switch
  looks like, marking a runtime available again, continuing a chat with another runtime by hand.
- `docs/reference/settings.md` — change: the pool, its switch, the per-chat opt-out.
- `docs/reference/runtimes.md` — change: for each runtime, whether its spent allowance is
  recognised and whether it states a return time.
- `docs/reference/events.md` — change: the runtime-switched event.
- `docs/reference/statuses.md` — change: the waiting-for-an-allowance status.

## Assumptions

- The pool is app-wide, not per project; a per-project pool can come later if wanted.
- A chat that has switched stays on its new runtime. It is not moved back when the first
  runtime's allowance returns, because each switch loses that runtime's private context; the
  person can move it back by hand.
- Carrying the conversation over means giving the new runtime the app's own record of it, not the
  old runtime's session. Runtimes have no way to take over each other's sessions.
- Recognition is built per runtime from what each actually sends when it runs out. Some wording
  will need capturing from real exhaustion, which may take waiting for a real limit.
- The one-hour retry for runtimes that give no return time is a default, not a setting, in this
  version.
- Mixing runtimes inside one chat is acceptable to the person; the chat does not try to hide it.
- Depends on: runtime sign-in status (043/048) to know which runtimes are usable; events (042);
  the blocked-and-check-again machinery (039) for the everyone-out wait; servers (037) for
  per-host pools.
