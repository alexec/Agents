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

## Clarifications

### Session 2026-09-25

- Q: Where does the person look at the state of the pool? → A: On a Pool page of its own. It is
  a row in the sidebar's Activity section, beside Events, Resources and Spending, and it is on
  the phone too. The pool is still edited in Settings, and the page links there.
- Q: How does the person say which settings a chat should have on the new runtime? → A: In two
  places. A **Continue with** sheet shows every setting side by side, old runtime and new, filled
  in with the app's best mapping, and the person can change any of them before the chat moves.
  A **Matching models** section on the Pool page keeps the mappings to use next time. Each row
  there is a level the person names (say "Strongest" or "Cheap and fast") with one model and
  effort per runtime in the pool. An automatic switch uses those rows. Its note in the chat can
  open the same sheet afterwards to correct what it chose.
- Q: Is a pool entry a runtime, or a runtime with a particular way of paying for it? → A: A
  runtime with its credential. The same runtime can be an allowance in one place and billed by
  the token in another. Codex on the Mac uses a ChatGPT plan, but on a server it is lent an
  OpenAI API key (047). Gemini only ever runs on a key (046). Antigravity uses a Google account on
  the Mac (the 049 Antigravity lane), and OpenCode and Goose use whatever provider the person has
  signed them in to. An API key is pay-as-you-go by nature, so falling back to one is exactly the
  pay-by-the-token carrying-on this feature exists to avoid. Each entry therefore shows how it is
  paid for: **allowance** (a plan or account sign-in: ChatGPT, Google account, Copilot, a Claude
  subscription, a subscription provider) or **billed per token** (an API key). Keyed entries can
  be added, but only by the person choosing them, marked as billed, and never offered by default.
  The same runtime can appear as two entries with different credentials, and on a server the
  entry is judged by the credential that host would actually use.
- Q: Does every "limit" refusal mean the runtime is out? → A: No. A spent allowance (a daily or
  monthly quota, a used-up plan window, credit gone) is told apart from a short rate limit (too
  many requests just now). Only a spent allowance marks the runtime out and moves the chat. A rate
  limit leaves the chat on its runtime, which is tried again after a short wait, and it switches
  only if the limit keeps coming back. The 046 Gemini lane's `usageLimit` recognition is the
  starting point. Today it treats a JSON-RPC 429, "quota", "rate limit" or "RESOURCE_EXHAUSTED" as
  one thing and ends the turn as a plain refusal with the provider's sentence. 052 splits that into
  the two kinds, per runtime. Gemini's spent free tier ("You have exhausted your daily quota on
  this model.") is the first captured example.
- Q: How is a spent allowance recorded, given that other lanes are changing the same list of
  endings? → A: As an ending of its own, beside the others in `EndedReason`, never folded into
  `refusal`. The Antigravity lane, uncommitted as of 2026-09-25, adds a `runtimeError` ending to the
  same enum, so whichever lane merges second takes the other's cases and re-runs the tests over
  every ending. The two stay distinct: `runtimeError` is a runtime reporting a failure in words,
  which FR-006 says never switches, and a spent allowance is one that has been positively
  recognised. The plan checks main for `runtimeError` and Gemini's `usageLimit` before adding
  anything.

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

### User Story 3 - A Pool page: which runtimes are out, until when, and what moved (Priority: P1)

The person wants one place to look at the state of their allowances. Beside Events, Resources and
Spending in the sidebar's Activity section there is a **Pool** row. Its page lists the pool in
order. Each runtime has a line that reads plainly: *Available*, *Out until 07:00*, *Out since
02:14, trying again after 03:14*, or *Can't be used: not signed in*. Next to each runtime is how
many chats are on it now. Under the list are the recent switches, newest first: when, which chat,
from which runtime to which, and why. Each one opens its chat. Any chats waiting for an allowance
to come back are listed at the top, each with the time it will resume.

From the page the person can mark a runtime as available again by hand, when they know better
(they bought more credit, or a new month began). There is also a link to where the pool is edited.
The sidebar row carries a small mark when any runtime in the pool is out, so the person can see
that without opening the page. The phone has the same page wherever it shows Spending.

New chats started on a runtime that is out warn before the first prompt and offer the first
available one instead.

**Why this priority**: The person asked for it. Switching that happens where nobody can see it is
hard to trust. Without this page, every other chat also hits the same wall one at a time, and the
person cannot tell why their chats moved.

**Independent Test**: On a scratch root with a pool of three:
1. Make one runtime report out with a reset time.
2. Make a second report out with no reset time.
3. Cause one switch.
4. Check that the Pool page shows each state in words, the chat counts, the switch with a working
   link to its chat, and the mark on the sidebar row.
5. Clear one runtime by hand, and check that the page and the mark update without a relaunch.

**Acceptance Scenarios**:

1. **Given** a pool where nothing is out, **When** the person opens the Pool page, **Then** every
   runtime reads Available, the switch list says there have been none, and the sidebar row has
   no mark.
2. **Given** A ran out with a stated reset time, **When** that time passes, **Then** A reads
   Available again on the page without the person doing anything, and the mark goes if nothing
   else is out.
3. **Given** A ran out without a stated reset time, **When** the person looks at the page,
   **Then** A reads as out since the time it ran out, and as tried again no sooner than one hour
   later.
4. **Given** A is out, **When** the person marks it available, **Then** the page, the mark and
   the next switch decision all treat A as available.
5. **Given** several chats on A, **When** A runs out in one of them, **Then** the others move the
   next time they would send A a turn, without first failing on A themselves.
6. **Given** the pool is empty or switching is off, **When** the person opens the page, **Then**
   it says so and links to where the pool is set up, rather than showing an empty list.

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

### User Story 5 - Continue with another runtime, saying what it should be (Priority: P2)

The person wants to move a chat to another runtime themselves. They might want to save one
allowance for later, or another runtime might be better at this kind of task. They pick
**Continue with…** on the chat and choose a runtime. A sheet opens with two columns: the settings
the chat has now, and what it will have on the new runtime. There is a row each for model, effort,
mode and any other option the new runtime offers. Each value on the right is filled in with the
app's best mapping:
- from the Matching models rows (Story 6), if the chat's current model is in one;
- otherwise by the rules in FR-015.

Each filled-in value says where it came from ("from Strongest", "same value", "runtime default").
The person can change any of them. Mode can only be set as loose as the chat's current mode, or
stricter. Settings that will not carry over are listed under the columns, in plain words: extra
command-line arguments, "always allow" answers, queued slash commands the new runtime lacks.

Under the columns is a switch: **Remember this for next time**. With it on, the chosen model and
effort are added to a Matching models row, or a new row is made, so the next switch between
these runtimes needs no correcting. The person confirms, and the chat moves without re-sending
anything.

The same sheet opens from an automatic switch's note in the chat, as **Change what it carried on
with**. There it changes the new runtime's settings from the next turn on. It does not undo the
turn already under way.

**Why this priority**: Only the person knows which model on one vendor stands in for which on
another. Without this, every switch lands on a default and has to be corrected by hand, chat by
chat.

**Independent Test**:
1. On an idle chat, open Continue with and pick a second runtime.
2. Check every row is filled in and each says where its value came from.
3. Change the model, turn on Remember, and confirm.
4. Check the chat is on the new runtime with that model, and the next prompt goes to it with the
   history.
5. Check a Matching models row now holds both models.
6. Open Continue with on another chat on the first runtime, with the same model, and check the
   new runtime's model is filled in from that row.

**Acceptance Scenarios**:

1. **Given** an idle chat on A, **When** the person continues it with B and confirms, **Then** the
   chat is on B with exactly the settings shown on the sheet, and its next prompt goes to B with
   the conversation so far.
2. **Given** a chat with a turn in flight, **When** the person picks Continue with, **Then** they
   are asked to stop the turn first.
3. **Given** the sheet, **When** the person tries to pick a mode looser than the chat's current
   one, **Then** it is not offered.
4. **Given** the sheet with Remember on, **When** the person confirms, **Then** the model and
   effort pair is saved as a Matching models row, or added to the row the old model was already
   in.
5. **Given** a chat that switched by itself, **When** the person opens Change what it carried on
   with from its note and picks another model, **Then** the next turn runs on that model, and the
   chat records the change.

---

### User Story 6 - Matching models, set up ahead of time (Priority: P2)

The person would rather settle the mapping once than correct it after every switch. The Pool page
has a **Matching models** section. It is a grid: one column for each runtime in the pool, and
one row for each level the person names. Each cell is a model, and an effort where the runtime
offers one, picked from what that runtime offers. A cell can be left empty. For example (the
model names are only illustrations):

| Level | Claude | Codex | Copilot |
|-------|--------|-------|---------|
| Strongest | Opus, high effort | gpt-5-codex, high | Claude Opus (via Copilot) |
| Everyday | Sonnet | gpt-5-codex, medium | GPT-5 |

When a chat switches, its current model is looked up in the grid. If that model is in a row, the
new runtime gets that row's cell. If the model is in no row, or the cell is empty, the pool
entry's model or the FR-015 rules decide, and the switch note says the grid had no answer.

The lists of models come from what each runtime says it offers, and the app asks for them without
starting a chat. If a cell names a model that a runtime has since stopped offering, the cell is
shown as gone and is not used.

**Why this priority**: It turns a correction that happens after every switch into one decision.
It builds on Story 5's sheet, which fills in the same rows.

**Independent Test**:
1. With a pool of two, add a row mapping a model on each.
2. Start a chat on the first runtime with that model.
3. Force a switch, and check the new runtime started on the row's model and the note says so.
4. Change the first runtime's model to one that is in no row, force a switch again, and check
   the note says the grid had no answer.

**Acceptance Scenarios**:

1. **Given** a row mapping model X on A to model Y on B, **When** a chat on A with X switches to
   B, **Then** it starts on Y, and the note says "from <row name>".
2. **Given** a chat on a model that is in no row, **When** it switches, **Then** the pool entry's
   model or the runtime's default is used, and the note says the grid had no answer.
3. **Given** a runtime that no longer offers a model named in a cell, **When** the person opens
   the page, **Then** that cell is shown as gone, and switches skip it.
4. **Given** a runtime is added to the pool, **When** the person opens the page, **Then** the grid
   gains an empty column for it.

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
- **Different options.** Mode and model do not map one to one between runtimes. See FR-015 for
  how each is carried. The chat never starts on the new runtime in a looser mode than it had.
- **Permissions given before the switch.** An "always allow" given to the old runtime was that
  runtime's own. The new runtime may ask again.
- **Queued slash commands.** A queued prompt that starts with a slash command the new runtime
  does not offer is held, and the chat says so. It is not sent as plain text.

## Requirements *(mandatory)*

### Functional Requirements

**Pool**

- **FR-001**: The person MUST be able to keep one ordered pool of runtimes, each with its
  credential and optionally a model, and add, remove and reorder its entries in Settings.
- **FR-001a**: Each entry MUST show whether it is an **allowance** (a plan or account sign-in) or
  **billed per token** (an API key). Keyed entries MUST NOT be suggested or added by default. A
  keyed entry the person adds MUST stay marked as billed on the Pool page and in every switch note.
  On a server, an entry MUST be judged by the credential that host would use.
- **FR-002**: Only installed, signed-in runtimes MUST be addable; entries that stop being usable
  MUST stay in the pool, shown as unavailable, and be skipped.
- **FR-003**: Switching MUST be off until the pool holds at least two runtimes, and the person
  MUST be able to turn it off for the whole app or for one chat.
- **FR-004**: The pool MUST survive restarts of the app and the daemon.

**Recognising a spent allowance**

- **FR-005**: The app MUST tell a spent allowance apart from every other way a turn ends, for each
  runtime it knows, and MUST record which one it was.
- **FR-006**: The app MUST NOT switch on any ending it does not positively recognise as a spent
  allowance, including crashes, refused sign-ins, the person's cost limits, context limits, short
  rate limits and a runtime's own error in words.
- **FR-006a**: A short rate limit MUST NOT mark a runtime out. The app MUST retry the turn on the
  same runtime after a short wait, and MUST treat the runtime as out only if the rate limit keeps
  coming back. A spent allowance MUST be recorded as an ending of its own, never as a plain
  refusal.
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
- **FR-015**: The chat's settings MUST be carried over in three kinds:
  - **Settings the app owns, carried as they are:** folder, worktree, extra folders, attached MCP
    servers, the app's own tools, project, cost ceiling and spending, and queued prompts. The
    app's tool policy is the new runtime's own, not a copy of the old one's.
  - **Settings the runtime advertises, mapped:**
    - *Mode:* the new runtime's loosest mode that is no looser than the chat's current mode,
      judged on the same scale as a helper agent's mode (028). If the current mode has no place
      on that scale, the chat MUST get the new runtime's strictest mode.
    - *Model and effort:* the Matching models row that holds the chat's current model, if that
      row has a cell for the new runtime. Otherwise the model named on the pool entry, else the
      model last chosen for that runtime, else the runtime's default. A model is never matched
      by name across vendors.
    - *Effort and any other option:* the same value if the new runtime offers that value under
      the same kind of option; otherwise the runtime's default.
    - *Extra command-line arguments:* dropped.
  - **Runtime-private state, not carried:** the runtime's own session, its compaction of the
    chat, its "always allow" answers and its slash commands.
- **FR-015a**: The switch note MUST say which mode and model the new runtime started in, where each
  came from, and any setting that could not be carried over.

**Pool page**

- **FR-019**: The sidebar's Activity section MUST have a Pool row, always present, that opens a
  page about the whole pool, on the Mac and on the phone.
- **FR-020**: The page MUST show, for each runtime in pool order, its state in words (available;
  out until a time; out since a time and when it will next be tried; unusable and why) and how
  many chats are on it now.
- **FR-021**: The page MUST list recent switches, newest first, each with its time, chat, the
  runtime it came from, the runtime it went to and the reason, and each MUST open its chat.
- **FR-022**: The page MUST list chats waiting for an allowance to return, with when each will
  resume.
- **FR-023**: The person MUST be able to mark an out runtime as available from the page.
- **FR-024**: The Pool row MUST show a mark whenever any runtime in the pool is out, and the page
  and mark MUST update as states change, with no relaunch.
- **FR-025**: Switches MUST be kept for the page for at least 30 days.

**Everyone out**

- **FR-016**: When no runtime in the pool is usable, the chat MUST stop with a note naming the
  earliest known return, and MUST resume on its own on the first runtime to come back when a return
  time is known.
- **FR-017**: A prompt from the person, or stopping, parking or archiving the chat, MUST cancel
  that automatic resume.

**By hand**

- **FR-018**: The person MUST be able to continue an idle chat with any usable runtime, from the
  Mac and from the phone, with nothing re-sent.
- **FR-026**: Continue with MUST show every setting the chat has now beside the value it will have
  on the new runtime. Each value MUST be filled in by the FR-015 rules and say where it came from,
  and the person MUST be able to change it before confirming. The settings that will not carry
  over MUST be listed.
- **FR-027**: The sheet MUST NOT offer a mode looser than the chat's current mode.
- **FR-028**: The sheet MUST offer to remember the chosen model and effort as a Matching models
  row.
- **FR-029**: An automatic switch's note MUST open the same sheet. Changes made there MUST apply
  from the chat's next turn, and MUST be recorded in the chat.

**Matching models**

- **FR-030**: The Pool page MUST have a Matching models grid: one column for each pool runtime and
  one row for each level the person names. Each cell holds a model, and an effort where the
  runtime offers one, chosen from what that runtime offers. A cell may be empty.
- **FR-031**: The model lists MUST come from what each runtime says it offers, fetched without
  starting a chat. A cell whose model is no longer offered MUST be shown as gone, and MUST NOT be
  used.
- **FR-032**: A model MUST appear in at most one row for each runtime, so that looking a model up
  gives one answer.
- **FR-033**: The grid MUST survive restarts, and MUST gain an empty column when a runtime is
  added to the pool.

### Key Entities

- **Pool**: the person's ordered list of acceptable runtimes; each entry is a runtime, the
  credential it runs on (allowance or billed per token), and an optional model. App-wide.
- **Runtime allowance state**: per runtime (and per host, for servers), available or out; when it
  ran out; when it is expected back, if known; how the app learned it.
- **Matching row**: a level the person names, with at most one model, and effort, per runtime.
  Rows are ordered and app-wide.
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
- **SC-007**: From anywhere in the app, the person can tell whether any runtime is out without
  opening anything, and with one click can see which ones are out, until when, and every chat
  that moved in the last 30 days.

- **SC-008**: Once the person has set up Matching models rows for their usual models, 9 of 10
  automatic switches start on the model the person would have picked, with no correction
  afterwards.

## Docs *(mandatory)*

- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — add: setting up the pool, what a switch
  looks like, reading the Pool page, filling in Matching models, using Continue with and its sheet, marking a runtime available again, continuing a chat with another runtime by hand.
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
- The short wait and the number of repeats before a rate limit counts as out are defaults set in
  the plan, not settings, in this version.
- Depends on: the per-runtime credential kinds from 046/047 to tell an allowance from a key;
  Gemini's `usageLimit` (046) as the first recogniser; runtime sign-in status (043/048) to know which runtimes are usable; events (042);
  the blocked-and-check-again machinery (039) for the everyone-out wait; servers (037) for
  per-host pools.
