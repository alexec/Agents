# Feature Specification: How It Actually Went

**Feature Branch**: `014-agent-outcomes`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "When an agent has completed its work, we show it as completed. However, agents often have questions outstanding for the user or things that were not actually completed. We need a new agent status that differentiates done done from done but still needs user input, a table of the different states of the work along with a message field, a single tool agents invoke at the end to report the actual status that works cohesively with the existing escalation tools, and something for when the agent stops working without invoking it."

## Why this feature exists

The app has one word for every turn that ends normally, and that word is **Complete**. Green tick,
"Complete" on the row, "Complete" in the panel heading, the same on the phone. It is derived from
`endTurn`, which is the protocol's way of saying *I am giving the turn back*, and the app reads it
as *the work is done*. Those are not the same sentence, and the gap between them is where this
feature lives.

An agent gives the turn back for all sorts of reasons. It finished. It finished four of the five
things and could not do the fifth. It wrote the migration and wants to know whether to run it before
it goes further. It looked at the nightly build, found nothing wrong, and had nothing to do at all.
It could not get started because the credentials were not there. Every one of those is `endTurn`,
and every one of those is currently a green tick that says Complete.

So the one group a person actually reads — **Needs attention**, the only place in this app that gets
colour — misses most of what needs them. Today it holds exactly the agents blocked mid-turn on a
permission or an elicitation form. An agent that asked its question by writing it in the transcript
and then stopping is filed under Complete with everything that genuinely is complete, and the only
way to find it is to open every conversation and read the bottom of each one. That is the opposite
of what the list is for. Worse, it teaches the person not to trust the tick: once you have opened
three "Complete" agents and found two with questions in them, you have to open all of them forever.

The fix is to stop inferring and start asking. The agent knows how it went — it is the only thing
that knows — so it should say, in a fixed vocabulary the app can act on, plus a sentence in its own
words. The app already has the shape for this: three tools it serves agents over its own MCP server,
each one a way for an agent to hand the app something the protocol has no room for. This is the
fourth, and it is the one that runs last.

And because some agents will not say — old runtimes, crashes, an agent that simply forgets — the
absence of a report has to be its own honest answer, not a tick borrowed from the agents that did
report. An unconfirmed ending is not a completion.

**This feature does not change what blocks an agent.** Permissions and elicitation still stop a turn
and still hold the runtime. This is about the moment after the turn, not during it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The question that was hiding under a tick (Priority: P1)

Someone comes back to a project with six agents in it. Four say Complete, two say Stopped. Today
they open all four to find out that one of them wrote "I've made the schema change, but I don't know
whether you want the index dropped first — let me know" and then ended its turn.

After this feature, that agent is not under Complete. It is under Needs attention with the colour
on it, and the line under its name is the agent's own sentence about what it wants to know. The
person reads the question from the list, types the answer into the prompt, and never opens the other
three — because the other three said, in their own words, that they are done.

**Why this priority**: This is the entire complaint. Everything else in this feature is an
elaboration of it. It is also the smallest shippable slice: one outcome that means "I need you"
alongside one that means "I am done" already makes the list trustworthy, and the rest of the table
can arrive after.

**Independent Test**: Run an agent that ends its turn by reporting that it needs an answer, with a
question as its message. Without opening the conversation, confirm from the agents list alone that
it is grouped as needing a person, carries the colour, and shows its question. Then run an agent
that reports it is done, and confirm it is under Complete and carries no colour.

**Acceptance Scenarios**:

1. **Given** an agent that reports at the end of its turn that it needs an answer, **When** the turn
   ends, **Then** it appears under Needs attention with the agent's message shown as its line, and
   the project it belongs to is marked as wanting a person.
2. **Given** that same agent, **When** the person sends a prompt answering it, **Then** the outcome
   is cleared and the agent is working again, with no leftover claim about the previous turn.
3. **Given** an agent that reports it is done, **When** the turn ends, **Then** it appears under
   Complete with its message as its line and no colour anywhere.
4. **Given** an agent reporting an outcome, **When** the person is looking at the conversation rather
   than the list, **Then** the outcome and its message are the last thing in the transcript, so the
   two views agree.

---

### User Story 2 - Four of five, and the fifth needs a decision (Priority: P1)

An agent is asked to update six call sites. It updates five. The sixth is in generated code and
changing it would be thrown away on the next build. It ends its turn saying so.

Today that is Complete, indistinguishable from six out of six. After this feature it reports that it
did part of the work, its message says which part and why the rest is not done, and the list shows
it as unfinished rather than finished. The person can see, without opening anything, that there is a
decision left on the table.

**Why this priority**: The user's phrase was "things that were not actually completed", and this is
the half of it that is not a question. An agent that stopped part way through is the most expensive
thing to miss, because the work looks done and the gap only surfaces later, in a build or a review
or production. It shares all the machinery of Story 1 and is worth the same priority for that reason.

**Independent Test**: Run an agent over a task with a part it cannot finish. Confirm from the list
alone that it is not described as complete, that it is grouped with the things needing a person, and
that its line says what was left.

**Acceptance Scenarios**:

1. **Given** an agent that reports it did part of the work, **When** the turn ends, **Then** it is
   grouped as needing a person and its line reads as unfinished rather than complete.
2. **Given** an agent that reports it could not do the work at all, **When** the turn ends, **Then**
   it is grouped as needing a person and its line says it is stuck, with the agent's reason.
3. **Given** an agent that reports there was nothing to do, **When** the turn ends, **Then** it is
   grouped as complete, carries no colour, and its line says there was nothing to do rather than
   that work was done.
4. **Given** any reported outcome, **When** the same agent is read on the Mac and on the phone,
   **Then** both say the same words about it.

---

### User Story 3 - The agent that said nothing (Priority: P2)

A turn ends and no outcome was reported. The runtime is an old one, or the agent forgot, or it ran
out of room mid-sentence. The app does not know how it went and must not pretend it does.

Two things happen. The app asks the agent, once, how it went — a great many silences are an agent
that simply forgot, and one question gets an answer out of it. And if that question comes back empty
too, the ending is labelled honestly as unconfirmed: it stays under Complete, where it does not
compete for the person's attention with the agents that asked for it, but it is marked so the person
can see that nothing vouched for it. The distinction is visible at a glance, so the person knows
which endings they can trust.

**Why this priority**: Without this, the feature quietly makes things worse rather than better: an
agent that does not report would keep the confident tick, and a person who has learnt to trust the
tick would now be wrong about exactly the agents nobody can vouch for. It is P2 rather than P1 only
because it has no value until at least one outcome exists to contrast it with.

**Independent Test**: Run an agent that ends its turn without calling the tool. Confirm it is asked
once, that the question is visibly the app's own, and that if it stays silent the app never
describes it as Complete and never asks a second time. Confirm its presentation is distinguishable
at a glance from an agent that reported being done.

**Acceptance Scenarios**:

1. **Given** a turn that ends normally with no outcome reported, **When** the agent settles, **Then**
   the app asks the agent for an outcome, once, and the question is visibly the app's rather than
   the person's.
2. **Given** that question coming back with an outcome, **When** it settles, **Then** the agent is
   treated exactly as one that reported the first time, and nothing marks it as having been asked.
3. **Given** that question coming back with no outcome either, **When** it settles, **Then** the app
   does not describe the agent as complete, says instead that the ending was not accounted for,
   leaves it under Complete rather than Needs attention, gives it no colour, and never asks again.
4. **Given** a turn that ends short — out of room, refused, cancelled, the runtime died — **When** the
   agent settles, **Then** the existing wording for that ending is what is shown, and no outcome is
   expected or implied.
5. **Given** an agent that reported an outcome and then had its process die before the turn closed,
   **When** the agent settles, **Then** both are shown: the ending it came to, and what it last said
   about the work.

---

### User Story 4 - The overnight run you read with coffee (Priority: P3)

A workflow fires at 3am and starts an agent nobody is watching. In the morning the project page has
a row for it. Today that row can say the run happened; it cannot say whether the run was any good.

After this feature the row carries the agent's own account of how it went, so a person scanning a
project can tell a clean nightly run from one that stopped half way and has been silently not doing
its job for four nights.

**Why this priority**: Unattended runs are where an unearned tick costs the most, because there was
nobody there to notice. But it is a second surface for a fact the earlier stories already establish,
so it can follow them.

**Independent Test**: Fire a workflow whose agent reports that it was blocked. Confirm the project
page's workflow row says so, without opening the agent.

**Acceptance Scenarios**:

1. **Given** a workflow run whose agent reports an outcome, **When** the run ends, **Then** the
   workflow's row shows that outcome alongside the existing record of the run having happened.
2. **Given** a workflow run whose agent reports an outcome needing a person, **When** the run ends,
   **Then** the project is marked as wanting a person for the same reason any other agent would mark
   it.

---

### Edge Cases

- **Reporting twice in one turn.** An agent that reports and then keeps working and reports again
  has changed its mind. The last report stands; the earlier one is not history worth keeping.
- **Reporting and then carrying on, and never reporting again.** The report was about an ending that
  did not arrive. It stands as the account of the turn when the turn does end — the alternative is
  discarding the only thing the agent said about its work.
- **Reporting while a permission or a form is still outstanding.** The agent is claiming an ending
  while it is mid-question. Refused, with a sentence saying why, because a person must not be told
  the work is settled while the app is still holding a question for them.
- **An outcome needing a person, on an agent the person then archives.** Archiving is a decision, and
  it wins: an archived agent is not in Needs attention, whatever it last said.
- **An empty or absent message.** Rejected. A status with no words is what the app already had.
- **An enormous message.** Cut to a readable length rather than refused, in the manner of a
  suggestion — losing the outcome over a long sentence would be worse than trimming it.
- **An outcome name the app does not know**, from a runtime or agent sending something newer. Treated
  as unaccounted for rather than rounded to the nearest one we do recognise, and the message is still
  kept and shown.
- **An agent that reports it needs an answer and is never answered.** It stays where it is
  indefinitely. There is no expiry — a question nobody answered is still a question.
- **A report arriving after the conversation is gone**, from a helper left behind by a dead runtime.
  Refused with a plain sentence, the way the other app tools refuse the same thing.
- **An outcome needing a person while no window is open.** The outcome is still recorded; it is not a
  thing that needs somewhere to be shown in order to be true.
- **The person types while the app's question is in flight.** What they typed queues behind it, as
  any prompt queues behind a turn. They should not have to wait on a question they did not ask.
- **The person prompts before the question is sent.** The question is dropped. They have moved the
  work on, and asking an agent to account for a turn they have already superseded is noise.
- **The app's question arrives and the agent answers with prose rather than a report.** That is still
  no outcome. The ending stays unaccounted for, and nothing asks again.
- **A hundred turns end unreported in a burst**, from a runtime that will never call the tool. One
  question each, never more, and each countable — so the cost of asking is bounded by the number of
  endings and not by how long the runtime stays uncooperative.
- **The daemon restarts between the turn ending and the question being asked.** The question is not
  owed after the fact: an ending it never got to ask about is simply unaccounted for.

## Requirements *(mandatory)*

### Functional Requirements

**Saying how it went**

- **FR-001**: An agent MUST be able to report, in one call, how its work went: exactly one outcome
  from a fixed set, plus a message in its own words.
- **FR-002**: The set of outcomes MUST be fixed, small, and total over the question *what does the
  person do next*. There MUST be no free-form outcome and no outcome that leaves that question
  unanswered. The set is: **done**, **nothing to do**, **needs an answer**, **partly done**, and
  **stuck**.
- **FR-003**: A message MUST be required with every outcome. A report with an empty or missing
  message MUST be refused, and the refusal MUST say so in a sentence the agent can act on.
- **FR-004**: For **needs an answer**, the message MUST be the question itself, phrased so a person
  can answer it without reading the conversation it came from.
- **FR-005**: At most one outcome MUST stand per turn. A second report within the same turn replaces
  the first.
- **FR-006**: The outcome MUST be cleared when the next prompt is sent, in the same way and for the
  same reason as a suggested prompt: it is an account of the turn it came from, and a stale one is
  worse than none.
- **FR-007**: A report MUST be refused, with a plain sentence, when it comes from something that no
  longer speaks for a live agent.
- **FR-008**: A report MUST be refused, with a plain sentence, while a permission request or an
  elicitation for that agent is outstanding.
- **FR-009**: The reply to a successful report MUST tell the agent what became of it, in the manner
  of the app's other served tools.

**What the app does with it**

- **FR-010**: Every outcome MUST map to exactly one group in the agents panel and exactly one line of
  wording. The mapping MUST be total, so an outcome can never leave an agent in two groups or in
  none.
- **FR-011**: **Needs an answer**, **partly done** and **stuck** MUST group the agent under Needs
  attention and earn the app's one colour. **Done** and **nothing to do** MUST group it under
  Complete and earn no colour.
- **FR-012**: The word **Complete** MUST be reserved for an agent that reported **done**. No agent
  may be described as complete on the strength of its turn having ended.
- **FR-013**: The agent's message MUST be what the row and the card say about it, in preference to
  any wording the app would otherwise derive.
- **FR-014**: An outcome MUST NOT hold a runtime and MUST NOT block a prompt. An agent that needs an
  answer has given the turn back; the person answers by prompting it, not by filling in a form.
- **FR-015**: The outcome and its message MUST also appear at the end of the conversation, so the
  list and the transcript agree about the same turn.
- **FR-016**: An agent whose outcome needs a person MUST mark its project as wanting a person, and
  MUST reach the person through the same notification path as any other agent that needs them,
  exactly once per outcome.
- **FR-017**: The Mac and the remote MUST say the same words about the same outcome, which means the
  wording lives with the outcome and not in either view.
- **FR-018**: An archived agent MUST NOT appear under Needs attention whatever its outcome says.

**When nothing was said**

- **FR-019**: A turn that ends normally with no outcome reported MUST NOT be described as complete.
  It MUST stay under Complete rather than move to Needs attention, and MUST read as an ending the
  agent did not account for, marked distinguishably from a reported **done**. It MUST NOT earn the
  app's colour: an ending nobody vouched for is a thing to know, not a thing to do.
- **FR-020**: When a turn ends normally with no outcome reported, the app MUST ask the agent for one,
  exactly once.
- **FR-021**: That ask MUST NOT recur. An ask that itself ends with no outcome MUST leave the agent
  unaccounted for and MUST NOT produce another, for that turn or for the turn the ask created.
- **FR-022**: The ask MUST be distinguishable, wherever the conversation is read, from a prompt the
  person typed, and MUST NOT be attributed to the person.
- **FR-023**: The ask MUST NOT be made for an agent that is archived, that ended short, or that the
  person has already sent a prompt to. A prompt from the person supersedes the ask.
- **FR-024**: What the ask costs MUST be counted against the agent as any other turn is, so that a
  turn the app started on its own is never spending the person cannot see.
- **FR-025**: A turn that ends short — out of room, its limit, a refusal, cancelled, a dead process,
  a gone daemon — MUST keep its existing wording, MUST NOT have an outcome expected or implied for
  it, and MUST NOT be asked for one.
- **FR-026**: Where an agent reported an outcome and then ended short anyway, both MUST be shown: how
  it ended, and what it last said about the work.
- **FR-027**: An outcome the app does not recognise MUST be treated as unaccounted for rather than
  rounded to a known one, and its message MUST still be kept and shown. It MUST NOT earn an ask: the
  agent said something, and asking again would be pestering it for a word rather than an answer.
- **FR-028**: The app MUST tell agents, where it tells them anything, that reporting an outcome is
  the last thing they do.

**Alongside the tools that already exist**

- **FR-029**: Reporting an outcome MUST NOT block. It returns at once and the agent's turn ends
  afterwards in the ordinary way.
- **FR-030**: The division between this and the tools that interrupt MUST be stated where agents can
  read it: an agent that can carry on once it has an answer asks for that answer with the tools that
  block; an agent that cannot carry on reports that it needs an answer and gives the turn back.
- **FR-031**: Reporting an outcome MUST be compatible with, and independent of, suggesting next
  prompts and showing a file. An agent may do all three at the end of a turn, and none of them may
  overwrite another.
- **FR-032**: Showing a file MUST continue to pull an agent into Needs attention on its own, as it
  does today, and MUST NOT be confused with or replaced by an outcome.

**Unattended work**

- **FR-033**: A workflow run's agent outcome MUST be visible on the workflow's row, alongside the
  existing record of whether the run happened.
- **FR-034**: A workflow run whose agent reports an outcome needing a person MUST mark the project
  as wanting a person for it.

### Key Entities *(include if data involved)*

- **Work outcome**: One agent's account of how a turn's work went. Exactly one of five values —
  done, nothing to do, needs an answer, partly done, stuck — together with the agent's message and
  the moment it was reported. Held against the agent; replaced by a later report in the same turn;
  cleared when the next prompt goes.
- **The outcome table**: The fixed mapping from each outcome to the group it puts an agent in, the
  line the app draws under the agent's name, and whether it earns colour. Held once, so that the
  window, the phone and the project page cannot come to describe the same outcome differently.

  | Outcome | Means | Group | Reads as | Colour |
  |----------------|-------------------------------------------------|-----------------|-------------------------|--------|
  | done | Asked for, and done | Complete | the agent's message | no |
  | nothing to do | Looked, and there was nothing to do | Complete | the agent's message | no |
  | needs an answer | Cannot go further until a person answers | Needs attention | the agent's question | yes |
  | partly done | Some of it done, the rest needs a decision | Needs attention | the agent's message | yes |
  | stuck | Could not do it, and says why | Needs attention | the agent's message | yes |
  | *(none)* | The turn ended and nothing was said | Complete | not accounted for | no |

- **The report**: The single act by which an agent hands an outcome to the app. One call, one
  outcome, one message, at the end of the work. Refused when it cannot be honoured, and the refusal
  is a sentence rather than a code.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No agent is ever described as complete unless it said so itself. Verifiable by
  exhausting every combination of ending and outcome: none of them produces the word Complete without
  a reported **done**.
- **SC-002**: A person returning to a project can identify every agent that needs them from the
  agents list alone, opening none of them, in 100% of cases where an agent reported needing one.
- **SC-003**: For an agent that needs a person, the list says *what* it needs, not only that it needs
  something — the person can tell whether to answer a question, make a decision or unblock it before
  opening anything.
- **SC-004**: The same agent read on the Mac and on the phone produces identical wording about its
  outcome, for every outcome in the table.
- **SC-005**: Time to triage a project of ten finished agents drops from opening all ten to opening
  only those the list has already flagged — a reduction in conversations opened of at least 70% when
  most agents are genuinely done.
- **SC-006**: Every outcome maps to exactly one group and one line, demonstrated by exhausting the
  table; no combination of state and outcome leaves an agent ungrouped or in two groups.
- **SC-007**: Within a month of the feature being in use, at least 90% of turns that end normally
  carry a reported outcome, measured over the agents in the store.
- **SC-008**: A person scanning a project page can tell a clean unattended run from a run that
  stopped short, without opening the agent, in 100% of runs whose agent reported.
- **SC-009**: No ending is ever asked about more than once, demonstrated by exhausting the paths into
  an unreported ending; the count of questions never exceeds the count of unreported endings.
- **SC-010**: The Needs attention group contains only agents that asked for a person — never an agent
  that merely failed to say anything — so the group stays short enough to read whatever share of
  runtimes have adopted the tool.

## Assumptions

- The report arrives the way the app's other agent-facing affordances arrive — over the MCP server
  the app already serves every session, bound to the agent by the token minted for that session.
  Nothing new is installed and no new transport is introduced.
- Five outcomes is the whole table. It was chosen to be total over *what does the person do next*
  rather than over *what happened*, which is why there is no separate outcome for "failed" as
  distinct from "stuck", and none for "succeeded with warnings" — a warning is either something a
  person must act on, in which case it is partly done or stuck, or it is not, in which case it
  belongs in the message.
- **Needs an answer** is a settled state, not a blocking one. It does not hold a runtime, does not
  queue prompts and is not the same thing as `waitingOnUser`, which exists for questions asked
  mid-turn. Whether the group heading needs new words to hold both is a presentation question for
  the plan, not a requirement here.
- The existing endings — out of room, refused, cancelled, dead process, gone daemon — keep their
  current wording unchanged. This feature adds an account of the *work*; it does not restate how the
  *turn* ended.
- The notification a person gets for an outcome needing them is the one that already exists for
  agents that need a person. No new notification category is introduced.
- Runtimes will not all call the tool, and some never will. The design assumes partial adoption from
  the first day and does not depend on any runtime's cooperation to remain honest. That is why an
  unaccounted-for ending stays under Complete: putting it in Needs attention would be more honest in
  the abstract and useless in practice, because during partial adoption it would fill the one
  coloured group with agents that are probably fine, and a group nobody can read is worth nothing.
- One question, and only one, is the whole of the remedy for a silent ending. A second would be an
  argument with the agent, and an unbounded number would let a runtime that never calls the tool
  double the cost of every turn it takes.
- Prompting an agent is how a person answers a **needs an answer** outcome. No new answer affordance
  is introduced for it.
- Agents are told about the tool through its own description, which is the only channel the app has
  to every runtime.
