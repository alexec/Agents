# Feature Specification: What Every Agent Is Told

**Feature Branch**: `016-agent-briefing`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "We need to seed agents with important information, such as they should use the workflow management tool to manage workflows and escalation tool to make escalations and later on a status tool to indicate what task status is."

## Why this feature exists

This app owns a handful of things no runtime can do for it. A turn ends by saying what might come
next. A file is put in front of the person in the pane beside the conversation. A standing
arrangement — a prompt that runs itself — comes to exist. A question that is the person's to answer
is held by the daemon, outlives the window, and reaches a phone. Soon, under 014, an agent will say
how its work actually went rather than leaving the app to guess from `endTurn`.

Every one of those is a tool the app serves, and every one of them is worthless if the agent never
calls it.

We know what happens when a tool is offered and nothing else is done, because it was measured. With
`suggest_next_prompts` in the tool list and no words about it anywhere, the Claude adapter, Copilot
and Grok called it **exactly never**, however the description was reworded — and the description had
been reworded several times. With one sentence added to the conversation, Claude and Grok both came
back with four suggestions on the next turn. The finding generalises, and it is the whole premise of
this feature: **a tool description is a menu, read by something already looking for a tool; a prompt
is an instruction, read every time.** Anything this app needs an agent to *do*, as against merely be
able to do, has to be said in words.

There is exactly one lever for that — words in the conversation — and today it carries one sentence,
about one tool. Everything else the app owns is left to a description nobody reads at the moment it
matters:

- An agent asked to do something with two defensible answers **guesses**, or writes the question into
  the bottom of a reply and ends its turn. The app has a question channel that survives the window
  closing and reaches the person's phone, and the agent does not know to use it, so the question sits
  in a transcript nobody has open.
- An agent asked to make something happen every morning writes a **crontab entry**, or a shell script
  with a comment saying to add it to cron, or a note in a README addressed to a human who will never
  read it. The app owns standing arrangements; the agent has no idea.
- When 014 lands, an agent will finish four of five things and end the turn, and the app will call
  that **Complete** — unless the agent has been told there is somewhere to say otherwise.

This is the other half of 015. That feature takes away the runtime's own competing tools, so the
agent cannot schedule a job with `CronCreate` or raise a question with somebody else's
`escalation_raise`. Taking the wrong doors away does not tell an agent which door is right. 015
removes; this one points. Neither is much use alone: an agent with nothing but our tools and no words
about them falls back on prose and stops, and an agent told to use our tools while its own remain in
reach often uses its own.

What we add has to be **cheap**. It is paid for on the first prompt of every conversation, for every
agent, forever. It has to be **quiet**: the transcript is a record of what the person said, and
putting the app's words in the person's mouth makes it a record of something that did not happen.
And it has to have **room**, because the next line — 014's — is already known about, and adding it
should not mean reopening this decision.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The question that was never asked (Priority: P1)

Someone sets an agent on a schema change and goes out. The agent finds two reasonable orders to do it
in — drop the index first or migrate first — and one of them is slow to undo. It picks one, because
nothing told it there was anybody to ask.

After this feature, it asks. The question goes out the way this app carries questions: held by the
daemon, waiting however long it waits, drawn on the phone in the person's pocket. They answer it on
the bus. The agent carries on with the answer rather than with a guess, and the work that came back
is the work they wanted.

**Why this priority**: This is the one with a cost attached. A suggestion that never appears is a
missed convenience; a guess is work done wrong, sometimes irreversibly, and the app already has the
machinery to have prevented it. It is also the line that most needs saying, because an agent's
strongest instinct is to finish the turn.

**Independent Test**: Give an agent a task with two defensible answers and no stated preference,
across each supported runtime, and see whether a question reaches the app rather than a choice
reaching the diff.

**Acceptance Scenarios**:

1. **Given** an agent on its first prompt of a conversation, **When** the prompt reaches the runtime,
   **Then** it carries words telling the agent to put decisions that are the person's to the person,
   with a question or form, rather than guessing at them.
2. **Given** an agent that has been told this, **When** it meets a choice it cannot make, **Then** it
   raises a question the app can hold and carry, rather than ending its turn with the question
   written into its reply.
3. **Given** such a question raised while no window is open, **When** the person opens the app or
   their phone later, **Then** the question is still there to answer.

---

### User Story 2 - The crontab nobody will ever run (Priority: P1)

Someone asks an agent to check the build every morning and tell them if it is red. The agent writes a
shell script, writes a cron line into a comment at the top of it, and reports that the job is set up.
Nothing is set up. Nothing will ever run it. The person finds out a fortnight later, when the build
has been red for three days.

After this feature, the agent knows that "every morning" is a thing this app owns, creates it as a
workflow, and the person is asked to approve it in plain words before it exists. It then runs every
morning, in the app, where they can see it, change it, and turn it off.

**Why this priority**: Same shape as the first — the app has the machinery and the agent does not
know — and the failure is worse than doing nothing, because the person is told it is handled.

**Independent Test**: Ask an agent for something recurring and see whether a workflow appears for
approval, or a script does.

**Acceptance Scenarios**:

1. **Given** an agent that has been briefed, **When** the person asks for something to happen on a
   schedule or in response to something, **Then** the agent uses the app's workflow tool rather than
   writing cron entries, launch agents, or scripts nothing will run.
2. **Given** the same agent, **When** it is doing ordinary work nobody asked to be repeated,
   **Then** it creates no workflow at all.
3. **Given** an agent that does create one, **When** the write is attempted, **Then** the person is
   still asked first, exactly as they are today — the briefing changes what an agent reaches for, and
   changes nothing about who approves it.

---

### User Story 3 - The next line joins without a rewrite (Priority: P2)

014 adds a fifth thing the app owns: the agent's own account of how its work went. On the evidence
here, that tool will be called by nobody unless it is named in the conversation too.

After this feature, adding it is one line in one list. Nothing about when the words are sent, what
they cost, or where they appear has to be decided again, and no existing sentence has to be reopened
to make room.

**Why this priority**: It is not worth much on the day it ships, and it is worth a great deal on the
day after — this is the third tool to need the same treatment, and pretending there will not be a
fourth is how the one-sentence version came to be the thing being replaced.

**Independent Test**: Add a fourth line and confirm nothing else changes to accommodate it.

**Acceptance Scenarios**:

1. **Given** a new tool the app serves, **When** it needs an agent told about it, **Then** its line
   joins the others without changing when or how the briefing is sent.
2. **Given** a line added, **When** the briefing is next sent, **Then** it is carried in the same
   single block as the rest.

---

### User Story 4 - The conversation that does not pay twice (Priority: P2)

The person has a long conversation with an agent: forty prompts over an afternoon. They are not
charged forty times for the app's housekeeping, and when they scroll back through what was said, they
read their own words and the agent's — not the app's instructions wedged into every message they
typed.

**Why this priority**: The economics decide whether this can grow at all. A briefing sent every turn
is one that has to be kept to a sentence forever; a briefing sent once can afford to say what needs
saying. The transcript half is about trust — a record that shows words the person did not type is not
a record.

**Independent Test**: Run a multi-prompt conversation and inspect both what reached the runtime and
what the transcript holds.

**Acceptance Scenarios**:

1. **Given** a conversation that has already had its first prompt, **When** the person sends another,
   **Then** the briefing does not go again.
2. **Given** a runtime that has lost the conversation and a new one has to be begun, **When** the next
   prompt goes, **Then** the briefing goes with it, because the history that held it is gone.
3. **Given** any prompt carrying the briefing, **When** the person reads the transcript, **Then** it
   shows what they actually said, with the app's words not attributed to them.

---

### Edge Cases

- **A runtime that ignores it.** Some will. The briefing is an instruction, not a guarantee, and
  every feature it points at must still behave sanely when its line is ignored — the same way
  suggestions simply do not appear today.
- **A conversation picked back up after the daemon restarts.** Not briefed again. The runtime replays
  its own history, and that history already contains it; sending it again is paying twice.
- **A runtime that has lost the conversation.** Briefed again, with the first prompt of the new one.
  This is the only case where it goes a second time.
- **An agent started by a workflow rather than by a person.** The briefing speaks in the person's
  voice, because it is sent inside the person's turn. A workflow-started agent has no person in the
  loop at that moment, and some of what the briefing says — ask me, I might want — reads oddly. It is
  still sent: the person is not there *yet*, and a question raised for them to find later is exactly
  what the app's question channel is for.
- **The person's first prompt is itself about a workflow.** The briefing and the request say the same
  thing. Harmless, and preferable to the alternative of trying to detect it.
- **The person's first prompt contradicts the briefing.** The person wins. The briefing is the app's
  standing instruction and the prompt is the person's specific one.
- **The agent mentions the briefing in its reply.** It should not, and it is told not to. When it
  happens anyway the person sees the app talking about itself — untidy, not harmful, and not worth
  machinery to prevent.
- **A named tool the agent does not have.** Naming a tool the agent cannot see invites it to try and
  fail. Any line about a tool must be defensible for every agent it is sent to — which is a live
  concern precisely because 015 is about changing which tools an agent has.
- **A tool the app does not own.** The app's question channel is reached through the runtime's own
  tool, and each runtime spells that differently. A line about escalation therefore has to ask for
  the *act*, and be right whatever the runtime happens to call it.
- **An agent that takes the workflow line as an invitation.** An agent told it can schedule things
  will schedule things, and a workflow that starts an agent that writes a workflow is the shape the
  chain-depth limit exists to contain. The restraint has to live in the sentence, not only in the
  limit.
- **A very long briefing.** An agent told six things at once follows the first two. Length is a real
  failure mode and not just a cost, and it gets worse silently as lines are added.
- **A prompt that is attachments only, or a slash command.** The briefing still goes with the first
  prompt of the conversation, whatever that prompt is made of.

## Requirements *(mandatory)*

### Functional Requirements

**What is said**

- **FR-001**: The app MUST send every agent, in words, the things it needs the agent to *do* with the
  tools the app serves. A tool description MUST NOT be relied on to produce behaviour.
- **FR-002**: The briefing MUST tell the agent to end a turn by offering the person what they might
  want to ask next, as it does today, with no change in wording or effect.
- **FR-003**: The briefing MUST tell the agent that a decision belonging to the person — a choice
  between real alternatives, a missing credential, anything hard to undo — is to be put to the person
  as a question, rather than guessed at or written into the end of a reply.
- **FR-004**: The escalation line MUST ask for the act rather than name a tool, because the tool
  belongs to the runtime and differs between them. It MUST give the reason the app can vouch for:
  such a question is held for the person, survives the window closing, and reaches them on their
  phone.
- **FR-005**: The briefing MUST tell the agent that anything the person asks to happen on its own —
  on a schedule, or in response to something — is this app's to arrange, naming the tool that does
  it, and MUST say not to write cron entries, launch agents, or scripts that nothing will run.
- **FR-006**: The workflow line MUST also carry the restraint: the agent is not to create a standing
  arrangement nobody asked for.
- **FR-007**: Where the briefing names a tool, it MUST name it exactly as the agent will find it, so
  the agent can call it rather than guess at what it is called.
- **FR-008**: The briefing MUST NOT name a tool that the agent it is being sent to does not have.
- **FR-009**: The briefing MUST tell the agent not to mention it, or the tools it names, in what it
  says back to the person.

**When it is sent**

- **FR-010**: The briefing MUST be sent with the first prompt of a conversation, and MUST NOT be sent
  again while that conversation lasts.
- **FR-011**: The briefing MUST be sent again, and only again, when a runtime has lost the
  conversation and a new one has to be begun in its place.
- **FR-012**: A conversation picked back up after a daemon restart MUST NOT be briefed again.
- **FR-013**: The briefing MUST go as one block, separate from the person's own words, appended after
  them.
- **FR-014**: Every agent MUST be briefed, however it was started — by the person, by a project lead,
  or by a workflow.

**What it must not disturb**

- **FR-015**: The transcript MUST record the person's words alone. The briefing MUST NOT appear in
  the record as something the person said.
- **FR-016**: The briefing MUST NOT change who approves anything. Every confirmation that stands
  today — a workflow write being put to the person, a permission being asked — MUST still stand.
- **FR-017**: Removing the briefing entirely MUST leave every feature it points at still working. It
  makes those features happen on their own; it is not what makes them possible.

**Room for the next line**

- **FR-018**: The briefing MUST be composed of separate lines, one per thing the agent is told, so a
  new one can be added without rewriting the others or revisiting when and how the briefing is sent.
- **FR-019**: There MUST be a stated ceiling on how long the briefing may get and how many things it
  may say, enforced automatically, so that growth is a decision somebody makes rather than something
  that happens.
- **FR-020**: 014's outcome report MUST be able to join as one line, on the day it exists, with no
  other change.

### Key Entities

- **Briefing**: The whole of what an agent is told before it starts — every line, in a fixed order,
  carried as one block. Owned by the app, not by any one feature.
- **Line**: One thing an agent is told, about one thing the app owns. Belongs with the feature it
  serves, and says both what to do and what not to.
- **First prompt of a conversation**: The moment the briefing is paid for. Not the first prompt to an
  *agent* — an agent may outlive several runtime conversations, and each new one needs briefing
  again.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Given a task with two defensible answers and no stated preference, an agent puts the
  question to the person rather than choosing for them, on every supported runtime that offers a way
  to ask. Measured on live runs, not fakes, because the whole premise of this feature came from a
  live run.
- **SC-002**: Given a request for something recurring, an agent produces a workflow put to the person
  for approval, and produces no cron entry, launch agent, or unrunnable script, on every supported
  runtime.
- **SC-003**: An agent creates no standing arrangement in a conversation where none was asked for.
- **SC-004**: A conversation of any length carries the briefing exactly once, and a conversation
  whose runtime lost it carries it exactly twice. Countable from what reaches the runtime.
- **SC-005**: The transcript of a briefed conversation contains nothing the person did not say.
- **SC-006**: Adding 014's line is a one-line change, with no edit to any existing line and no change
  to when or how the briefing is sent.
- **SC-007**: The briefing stays within its stated ceiling, and exceeding it fails the build rather
  than shipping.
- **SC-008**: With the briefing removed, every feature it names still works when driven by hand.

## Assumptions

- **The measurement generalises.** One tool, three runtimes, and a clear result: a described tool went
  uncalled and a mentioned tool got called. This feature assumes the same holds for the other tools
  the app serves. It is an assumption, and the live runs in SC-001 and SC-002 are what test it.
- **Once is enough.** Words sent on the first prompt are assumed to hold for the conversation,
  because the runtime replays its own history. A runtime that summarises or truncates that history
  may drop them, and an agent that stops following the briefing late in a long conversation is the
  symptom to watch for.
- **The person's voice.** The briefing is sent inside the person's turn and so is written as the
  person speaking, which is what the existing sentence does.
- **015 is a sibling, not a dependency.** This can ship before, after, or alongside runtime tool
  scoping. They are worth most together — one points at the right door, the other takes away the
  wrong ones — but neither blocks the other.
- **014 is not a dependency either.** Its line joins when its tool exists. Until then the briefing
  says nothing about outcomes, because naming a tool that is not there is worse than saying nothing.
- **No per-project or per-agent briefing.** Every agent is told the same things. A project's own
  standing instructions are a separate idea, and if it turns out to be wanted, it is a feature of its
  own rather than a variation smuggled in here.
