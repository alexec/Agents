# Feature Specification: One Call to End a Turn

**Feature Branch**: `023-end-of-turn-tool`

**Created**: 2026-09-23

**Status**: Draft

**Input**: User description: "Merge suggest_next_prompts and report_outcome into a single end-of-turn app tool. One call, made once at the very end of a turn, carries how the work went (the existing five-value outcome enum plus a one-or-two-sentence message) and, optionally, one to four suggested next prompts for the person. The two tools fire at the same moment today, and the briefing has to spend a sentence ordering them; one tool removes a briefing line and a call per turn, and makes an unaccounted ending mean exactly one thing: the agent never finished. The old tool names stay listed and accepted as aliases, because the briefing is sent once and lives in the runtime's history, so a conversation resumed after the change will still call the old names. The daemon's existing refusal while a permission or form is pending applies to the whole call. show_file and manage_workflows are out of scope and stay separate: they fire at different moments for different reasons. The briefing's suggestions and outcome lines collapse into one."

## Why this feature exists

The app asks every agent to do two things at the end of every turn, and they are the same thing
said twice. One call offers the person two to four things to say next, shown as chips above the
prompt. The other says how the work went, in one of five words and a sentence, and is what the
agents list reads. Both are "the last thing you do". Neither can be done earlier and neither has
anything to do until the work is over.

Because there are two, the app spends words keeping them in order. The briefing, which is the only
thing that has ever reliably got an agent to call either one, has a line for each and a clause
tying the second to "that same turn". The outcome tool's description says "after everything else
including suggest_next_prompts". The briefing's own rule is that an agent told six things follows
the first two, and here two of the six are one instruction split in half.

Two calls also leave a gap the app then has to explain. An agent can post its chips and stop,
which today is a row that says "Finished without saying how it went" underneath a fresh row of
suggestions the agent was clearly present to write. The ending was unaccounted for by a tool call
and accounted for by another, and the person cannot tell which to believe.

So the two become one. A turn ends with one call that says how it went and, if there is anything
worth saying, what might come next. The briefing loses a line and its ordering clause, every turn
loses a call, and an ending nobody accounted for means exactly one thing: the agent never
finished.

The one thing this must not break is a conversation already under way. The briefing is sent once,
on the first prompt, and lives in the runtime's own history; that history is what a runtime replays
when a conversation is picked back up. A conversation briefed before this change and resumed after
it will call the tools by the names it was told, and it must find them.

**What this does not touch.** Showing a file and managing workflows stay as they are. The first
fires before the first write of a document, the second only when the person asks for something
recurring. Neither belongs at the end of a turn, and neither is a thing an agent should have to
find inside another tool.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The turn ends in one breath (Priority: P1)

An agent finishes a piece of work. It makes one call: this is how it went, in one of the five
words and a sentence, and here are three things you might ask me next. The row in the agents list
reads the agent's sentence under the right heading. The chips appear above the prompt. Nothing
else was needed, and nothing else was called.

**Why this priority**: This is the feature. Everything else here is what has to stay true while
it lands.

**Independent Test**: Run an agent that ends its turn with one call carrying an outcome, a message
and two prompts. Confirm from the agents list that the outcome and message are shown as they are
for a reported outcome today, and from the conversation that the two chips are above the prompt.
Confirm no second call was made and none was asked for.

**Acceptance Scenarios**:

1. **Given** an agent at the end of its work, **When** it makes the one call with an outcome, a
   message and one to four prompts, **Then** the agent is grouped and worded exactly as a report of
   that outcome is today, and the prompts are shown as chips exactly as suggestions are today.
2. **Given** the same call with no prompts, **When** the turn ends, **Then** the outcome and message
   are recorded and shown, and no chips are shown.
3. **Given** the one call, **When** the person sends their next prompt, **Then** both the outcome
   and the chips are cleared together, as each is today.
4. **Given** the one call made while a permission or form for that agent is still waiting,
   **When** it arrives, **Then** the whole of it is refused with a sentence, and neither the outcome
   nor the chips are shown.
5. **Given** a turn that ends with no call at all, **When** the agent settles, **Then** it is asked
   once for an outcome as it is today, and the ask names the one tool.

---

### User Story 2 - A conversation that was told the old names keeps working (Priority: P1)

A person started a conversation last week. Its agent was told, in the briefing, to call
`suggest_next_prompts` and then `report_outcome`. The app is updated. The person picks the
conversation back up and sends a prompt. The agent does what it was told, by the names it was
told, and it works: chips appear, the outcome is recorded, and nothing in the conversation says a
tool was missing.

**Why this priority**: A change to a tool's name that strands every open conversation is not a
change the app can ship. This story is what makes Story 1 safe to land, and it is tested as its own
thing because it is the one path a fresh test would never exercise.

**Independent Test**: Take a conversation whose history contains the old briefing, resume it after
the change, and have its agent call the two old names in the old order. Confirm the result is
indistinguishable from one call by the new name. Then have it call only the old suggestion name and
confirm the chips appear and the ending reads as unaccounted for, exactly as it did before.

**Acceptance Scenarios**:

1. **Given** an agent that calls the old suggestion tool by name, **When** it does so with one to
   four prompts, **Then** the chips are shown as before.
2. **Given** an agent that calls the old outcome tool by name, **When** it does so with an outcome
   and a message, **Then** the outcome is recorded and shown as before.
3. **Given** an agent that calls both old names in either order, **When** the turn ends, **Then**
   the agent's state is the same as if it had made the one new call with the same values.
4. **Given** a fresh conversation, **When** the agent is briefed, **Then** the briefing names only
   the one tool, and never the old names.
5. **Given** the app's own once-only ask for an outcome, **When** it is sent to a conversation
   briefed with the old names, **Then** the agent can answer it by either name and the ending is
   accounted for.

---

### User Story 3 - The briefing gets shorter and agents still do it (Priority: P2)

The briefing an agent reads on its first prompt says, in one line, to end each turn with the one
call: how it went, a sentence, and two to four things to ask next. There is no second line for the
outcome and no clause ordering one after the other. Across the runtimes the app supports, agents
end their turns with the call as often as they ended with the report before.

**Why this priority**: Shortening the briefing is half of why this is worth doing, but it is the
half that can only be confirmed by running agents, and it can be measured after Story 1 has
landed.

**Independent Test**: Read the briefing sent to a fresh conversation on each runtime and confirm it
is one line shorter than before and contains no ordering between the two acts. Run a turn on each
runtime and confirm the turn ends with the one call.

**Acceptance Scenarios**:

1. **Given** a fresh conversation on any runtime, **When** its first prompt goes, **Then** the
   briefing carries one line for ending a turn, in place of the two it carries today.
2. **Given** a runtime whose own suggestion tool the app removes, **When** the app says what to use
   instead, **Then** it names the one tool.
3. **Given** a turn on each supported runtime, **When** the work is done, **Then** the turn ends
   with the one call at least as often as it ended with a reported outcome before the change.

---

### Edge Cases

- **Prompts with no outcome, by the new name.** Refused. The outcome is what the call is for; the
  prompts ride along. The refusal says which of the five outcomes the agent has to pick.
- **Prompts with no outcome, by the old suggestion name.** Accepted. That name means what it always
  meant, and an agent that was told to use it is doing as it was told.
- **An empty list of prompts.** The same as no prompts. The outcome is recorded and no chips are
  shown. A turn's outcome is never lost over a list the agent left empty.
- **More than four prompts.** Cut to four, best first, as suggestions are today. Not refused.
- **An outcome word the app does not know.** The whole call is refused with a sentence naming the
  five, as a report with an unknown word is refused today. Nothing is shown, prompts included: the
  agent reads the five and calls again, which is better than chips beneath an ending the app then
  has to call unaccounted for.
- **Two calls in one turn.** The last one is the whole account. A second call with no prompts
  after a first with prompts leaves no chips: the agent changed its mind about the ending, and the
  chips belong to the ending.
- **A new-name call followed by an old-name call, or the reverse.** Each part is replaced by the
  last thing that spoke to it. An old suggestion call after the one call replaces the chips and
  leaves the outcome; an old outcome call after the one call replaces the outcome and leaves the
  chips.
- **An outcome that needs an answer, with prompts.** Allowed. The chips may well be the candidate
  answers, and a person who can answer from a chip has been saved some typing.
- **A permission or form outstanding.** The whole call is refused, prompts included, with the same
  sentence the outcome tool gives today. Chips over an open question would tell the person the
  turn is over when it is not.
- **A call from something that no longer speaks for a live agent.** Refused with a plain sentence,
  the way every app tool refuses the same thing.
- **The old names in the tool list, read by a fresh agent.** Their descriptions say they are the
  older names for the one tool and point to it. The briefing does not mention them, so a fresh agent
  has no reason to prefer them.
- **A runtime that prefixes tool names.** Matched on the end of the name, as every app tool is
  today, for all three names.

## Requirements *(mandatory)*

### Functional Requirements

**The one call**

- **FR-001**: An agent MUST be able to end a turn with one call that carries how the work went and,
  optionally, what the person might say next.
- **FR-002**: The call MUST require exactly one outcome from the existing fixed set of five and a
  message in the agent's own words, under the same rules that govern a reported outcome today: no
  free-form outcome, no empty message, and for *needs an answer* the message is the question.
- **FR-003**: The call MAY carry a list of one to four suggested prompts, each a label and the
  prompt itself, under the same rules that govern suggestions today. A missing or empty list MUST
  mean no chips and MUST NOT cause the call to be refused.
- **FR-004**: A successful call MUST leave the agent in exactly the state that the two separate
  calls with the same values leave it in today: the same group, the same wording, the same chips,
  the same record in the conversation. This feature changes how the account arrives, not what the
  app does with it.
- **FR-005**: The whole call MUST be refused, with the sentence the outcome tool gives today, while
  a permission request or form for that agent is outstanding. No part of a refused call is shown.
- **FR-006**: The whole call MUST be refused, with a plain sentence, when it comes from something
  that no longer speaks for a live agent.
- **FR-007**: The reply to a successful call MUST tell the agent what became of both parts, in the
  manner of the app's served tools today.
- **FR-008**: At most one account MUST stand per turn. A later call replaces the earlier one in
  full, chips included.
- **FR-009**: The outcome and the chips MUST be cleared together when the next prompt is sent, as
  each is today.
- **FR-010**: The call MUST NOT block. It returns at once and the turn ends afterwards in the
  ordinary way, as reporting an outcome does today.

**The old names**

- **FR-011**: The old suggestion tool and the old outcome tool MUST remain listed to agents and
  MUST remain accepted, with their existing arguments and their existing rules, for as long as a
  conversation briefed with those names could be resumed.
- **FR-012**: A call by an old name MUST have the same effect on the agent as the matching half of
  the one call. An old suggestion call replaces the chips and leaves the outcome alone; an old
  outcome call replaces the outcome and leaves the chips alone.
- **FR-013**: The old names' descriptions MUST say they are the older names for the one tool and
  name it, so a fresh agent that reads the whole list is pointed at the right one.
- **FR-014**: Removing the old names later MUST be possible without changing anything else: no
  other behaviour may depend on their presence.

**What agents are told**

- **FR-015**: The briefing MUST tell an agent to end each turn with the one call, in one line, in
  place of the two lines it carries today, and MUST NOT contain a sentence ordering one act after
  the other.
- **FR-016**: The briefing MUST NOT name the old tools.
- **FR-017**: Wherever the app names a tool to use instead of a runtime's own suggestion tool, it
  MUST name the one tool.
- **FR-018**: The app's once-only ask, sent when a turn ends with no account, MUST name the one
  tool, and MUST accept an answer by either the new name or the old outcome name.
- **FR-019**: The one tool's description MUST say what each part is for and MUST keep the line the
  outcome tool draws today between ending a turn and asking a question that waits.

**What the app recognises**

- **FR-020**: Every place the app recognises a call as its own rather than the agent's work MUST
  recognise the one tool and both old names, matched on the end of the name so that a runtime's
  prefix does not matter.

### Key Entities *(include if feature involves data)*

- **The account of a turn**: What an agent says when its work is over. One outcome from the fixed
  set of five, one message, and zero to four suggested prompts. Held against the agent; replaced in
  full by a later account in the same turn; cleared when the next prompt goes. The outcome and the
  prompts are the same two things the app keeps today; this feature is about their arriving
  together.
- **The one tool**: The single act by which an agent hands the app its account. Its name is chosen
  in the plan. Refused when it cannot be honoured, and the refusal is a sentence.
- **The old names**: The two tool names agents were briefed with before this change. Each is a way
  of sending half an account. Kept so a resumed conversation finds what it was told, and removable
  later without touching anything else.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A turn that ends with an outcome and suggestions needs one call from the agent, not
  two, on every supported runtime.
- **SC-002**: A conversation briefed before the change and resumed after it ends its turns with
  chips shown and its outcome recorded, in 100% of cases where the agent calls the old names as
  briefed. No such conversation ever sees a reply saying a tool does not exist.
- **SC-003**: The briefing sent to a fresh conversation is one line shorter than today on every
  runtime, and contains no sentence ordering suggestions before the outcome.
- **SC-004**: Across the supported runtimes, the share of normally ending turns that carry an
  account is no lower after the change than the share that carried a reported outcome before it,
  measured over the agents in the store.
- **SC-005**: No agent ever shows chips beneath a row that says its ending was not accounted for,
  except one that called the old suggestion name alone. For a fresh conversation, that combination
  does not occur.
- **SC-006**: For every combination of new-name and old-name calls in one turn, the agent's
  resulting state is one of the states reachable by the two separate calls today, demonstrated by
  exhausting the combinations.
- **SC-007**: Every existing test of a reported outcome and every existing test of a suggestion
  still passes, by either name, without its expectations changing.

## Assumptions

- The one call arrives the way the app's other agent-facing tools arrive, over the server the app
  already serves every session, bound to the agent by that session's token. Nothing new is
  installed.
- The five outcomes, their wording, their grouping and their colour are exactly as 014 fixed them.
  Nothing here changes the outcome table, the once-only ask, the unaccounted-for ending, or what a
  workflow row shows.
- The chips keep their rules from the suggestion tool: at most four, best first, a short label and
  a prompt addressed to the agent, cleared on the next prompt.
- The old names are kept because the briefing lives in runtime history, not because any other
  conversation state names them. Once no resumable conversation could have been briefed with them,
  they can go. When that is depends on how long conversations are kept and is a decision for later,
  not for this feature. "At least one release" is the working floor.
- The old names remain in the tool list rather than being accepted silently, as the description
  asked, so that a runtime which checks a name against the list before calling it still finds it.
  Their descriptions point at the one tool so the list does not read as three end-of-turn tools.
- The one tool's name is a plan decision. The requirement is that it reads as the end of a turn
  and not as a status update, since the failure to avoid is an agent calling it mid-turn.
- The tool descriptions and the briefing are the only channel the app has to every runtime, and
  the briefing is the one that works. The live measurements behind the two existing lines apply
  here: the merged line has to be read every time, and the description has to say which of the
  five is true.
- Showing a file and managing workflows are untouched, and the live-artifacts work in 022 that
  touches the file tool is in flight in the same source. This feature lands after or beside it
  without changing that tool.
