# Feature Specification: Cost Limits

**Feature Branch**: `010-cost-limits`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "Cost Limits. The ability to cap and track both per agent and per day limits to control cost."

## Clarifications

### Session 2026-09-19

- Q: When an agent passes the per-agent limit mid-turn, is the turn cut short? → A: No. The turn it
  is in finishes, and then the agent takes no further prompt.
- Q: When the day's limit is reached, what happens to agents already running? → A: Each finishes the
  turn it is in and then holds. New agents and new prompts are refused from the moment the limit is
  reached.

Both answers say the same thing, and it is worth stating once as the rule the rest of this
specification follows: **the turn is the unit, and a limit never cuts a turn short.** A cap that
interrupts an agent part-way through can leave a half-applied edit, a tool call without its result,
and a conversation nobody can read — which costs more to clean up than the turn it saved. The price
of the rule is a known, bounded overshoot: one turn per agent, and only for agents already working
when the limit was reached.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent that runs away stops itself (Priority: P1)

Someone sets a chat going on a job that turns out to be much bigger than it looked. They walk
away. Today the agent keeps going for as long as it has something to do, and the only thing
standing between it and an unbounded bill is somebody watching the figure in the corner of the
window. They want to say, once, *no agent may spend more than this*, and have that be true of
every agent without their being there.

**Why this priority**: It is the whole point of the feature in its smallest honest form. The app
already shows what an agent has cost; it has never been able to act on it. One runaway agent is
the failure everybody fears, and this is the only story that prevents it. Shipping only this
already turns a number you watch into a number that holds.

**Independent Test**: Set a per-agent limit low enough to be reached in a few turns. Start one
agent and leave it. It stops on its own, its row says the limit stopped it, and the figure beside
it does not keep climbing.

**Acceptance Scenarios**:

1. **Given** a per-agent limit is set, **When** an agent's cost to date reaches it, **Then** the turn it is in finishes, the agent then stops, and the reader is told — on the agent's own row and in the conversation — that the limit is what stopped it and what it had spent.
2. **Given** an agent stopped by its limit, **When** the reader looks at it, **Then** the ending reads as the limit, not as a crash, a refusal, or a finish, and the conversation is whole to its last turn rather than broken off part-way.
3. **Given** an agent stopped by its limit, **When** the reader sends it another prompt, **Then** they are told it is at its limit and are offered the two things that would change that — raising the limit, or letting this one agent go on — and neither happens without their saying so.
4. **Given** an agent has been allowed to go on past its limit, **When** it spends further, **Then** the allowance covers that agent alone, is stated on its row, and no other agent's limit is changed.
5. **Given** a per-agent limit is set, **When** an agent has spent most of it, **Then** the reader can see that it is close before it stops, in the same place they already look for the cost.
6. **Given** no per-agent limit is set, **When** agents run, **Then** nothing stops them and nothing is said, exactly as today.
7. **Given** a runtime that does not report what it costs, **When** an agent runs on it with a limit set, **Then** the reader is told plainly that this agent cannot be measured and is therefore not capped, rather than being left to assume it is covered.

---

### User Story 2 - A day cannot cost more than you said (Priority: P2)

Someone runs several agents a day, and some of them start themselves — a workflow on a schedule,
a chain that fires off another agent. Any one of them may be within its own limit while the day as
a whole quietly costs several times what they intended. They want a ceiling on the day: when it is
reached, the app stops spending until tomorrow, whoever or whatever asked for the work.

**Why this priority**: A per-agent limit alone is not a budget — twenty agents under it is twenty
times it, and automation can produce twenty agents without anybody typing. This is the limit that
actually bounds the bill. It sits below Story 1 only because one runaway agent is the sharper and
more common failure, and because the daily ceiling is far more useful once every agent already has
its own.

**Independent Test**: Set a daily limit low enough to reach within a sitting. Run agents until it
is reached. Confirm nothing further starts — including a workflow firing on a schedule — that the
reader is told why, and that after the day rolls over work starts again with no action from them.

**Acceptance Scenarios**:

1. **Given** a daily limit is set, **When** the day's spend reaches it, **Then** no new agent starts and no new prompt is sent, each attempt says that the day's limit is the reason, and every agent then working finishes the turn it is in and holds.
2. **Given** the day's limit is reached, **When** a workflow fires, **Then** it is refused for that reason and the refusal is recorded on its row like any other, so automation stops as visibly as a person is stopped.
3. **Given** the day's limit is reached, **When** the day rolls over, **Then** work can start again without the reader doing anything, the day's figure starts from zero, and an agent that was holding can be prompted again where it stands rather than having to be started afresh.
4. **Given** the day's limit is reached, **When** the reader wants to carry on anyway, **Then** they can raise the limit for the day, and that act is theirs alone.
5. **Given** an agent has been running since before the day rolled over, **When** it spends after the rollover, **Then** that spend counts against the new day, not the old one.
6. **Given** the app or the machine is restarted part-way through a day, **When** it comes back, **Then** the day's total is what had already been spent, not zero.
7. **Given** agents that have been archived or have ended, **When** the day's total is worked out, **Then** what they spent today is still counted.

---

### User Story 3 - You can see what you are spending and how much is left (Priority: P3)

Someone wants to know, without doing arithmetic, three things: what this agent has cost, what
today has cost, and how much of what they allowed is left. Today the app can answer the first and
part of the second, and the third does not exist. A limit nobody can see approaching is a limit
that only ever arrives as a surprise.

**Why this priority**: The caps in Stories 1 and 2 are usable without it — they stop things
whether or not anybody is watching — but they are unpleasant without it, because the first
evidence of a limit is an agent stopping. It is also the half of the request the word *track*
asks for, and the smallest of the three to build on what already exists.

**Independent Test**: With both limits set, run an agent part-way to each. Without opening
anything, read off what the agent has spent, what today has spent, and how much of each limit
remains.

**Acceptance Scenarios**:

1. **Given** limits are set, **When** the reader looks at an agent, **Then** they can see what it has spent and how much of its limit is left, in the place the cost is already shown.
2. **Given** a daily limit is set, **When** the reader looks at the app's main surfaces, **Then** they can see what today has cost and how much of the day's limit is left, without opening a separate page.
3. **Given** a limit is most of the way spent, **When** the reader looks, **Then** it is evident that it is close to being reached, using the app's existing way of saying *this needs a person* rather than a new one.
4. **Given** spend is reported in more than one currency, **When** the totals are shown, **Then** each currency is shown as its own figure and none are added together or converted.
5. **Given** no limit is set, **When** the reader looks, **Then** they see what is spent, as they do today, and nothing about headroom that does not exist.
6. **Given** the reader is looking at the phone rather than the window, **When** an agent has been stopped by a limit, **Then** it says the same thing in the same words as the window.

---

### Edge Cases

- **A runtime that never reports a cost.** Cost is the runtime's own figure and some runtimes send
  none. An agent on such a runtime can never reach a limit and must never be shown as if it were
  covered by one; it must be named as unmeasured. It also contributes nothing to the day's total,
  which means the day's total is a floor, not a fact, whenever such an agent is running.
- **Overshoot.** The app learns what an agent has cost only when the runtime says so, and it never
  cuts a turn short, so a limit is always acted on after it has been passed. The overshoot is
  bounded — one turn per agent that was already working — and it is real. What is shown must be
  what was actually spent, even when that is more than the limit; a figure clamped to the limit
  would be a lie.
- **One turn that blows past the limit on its own.** A single long turn can pass the limit by a
  wide margin before it ends, and the rule that a turn is never cut short means it will. This is
  accepted: the alternative is interrupting the agent, which is the thing the rule exists to
  prevent. What must not happen is silence — the reader has to be able to see that it happened.
- **Two currencies.** The app never converts and never adds across currencies. A limit is a figure
  in one currency, and spend in another cannot be measured against it.
- **A limit lowered below what is already spent.** Setting a per-agent limit under an agent's
  existing total, or a daily limit under the day's total, means the limit is already reached. The
  reader must be told that at the moment they set it, not discover it when the next thing refuses.
- **A limit of zero.** Reads as *nothing may run*, and must behave that way plainly rather than as
  *no limit*.
- **The day's boundary moves.** The clock changes, the machine travels, or it sleeps through
  midnight. The day is the machine's own local day, and a day that is short or long because the
  clock moved is still one day.
- **An agent holding when the day rolls over.** An agent held by the day's limit has a finished
  turn and a readable conversation behind it. When the day rolls over it must become promptable
  again where it stands, rather than needing to be started afresh — otherwise the daily limit costs
  the reader every conversation that was open when it was reached.
- **Cost arriving after the end.** A final figure may arrive after an agent has ended or been
  archived. It still counts towards the day it was spent in.
- **A workflow stopped by the day's limit.** The workflow is not paused and its schedule is not
  disturbed; it refused one fire and will try again when it is next due.
- **An agent asking to spend more.** Nothing an agent or a workflow can do may raise a limit.

## Requirements *(mandatory)*

### Functional Requirements

**Setting the limits**

- **FR-001**: The reader MUST be able to set a maximum cost for any one agent, applying to every
  agent rather than to a chosen one.
- **FR-002**: The reader MUST be able to set a maximum cost for a day, applying to everything the
  app spends in that day.
- **FR-003**: Either limit MUST be able to be unset, and unset MUST be the state before the reader
  has said anything, so that the app behaves exactly as it does today until they do.
- **FR-004**: Both limits MUST survive the app being closed, the daemon being restarted, and the
  machine being restarted.
- **FR-005**: A limit MUST be a figure in one named currency, and only spend reported in that
  currency MUST count towards it. The app MUST NOT convert between currencies or add them together.
- **FR-006**: Setting a limit that is already reached MUST tell the reader so at the moment they
  set it.
- **FR-007**: Only the reader MAY set or raise a limit. No agent, no workflow, and no tool served
  to an agent MAY do so, and the app MUST NOT offer them any means to.

**What a limit does**

- **FR-008**: An agent whose cost to date reaches the per-agent limit MUST finish the turn it is in
  and MUST then take no further prompt. A limit MUST NOT cut a turn short.
- **FR-009**: When the day's total reaches the daily limit, no new agent MUST be started and no new
  prompt MUST be sent, and every agent then working MUST finish the turn it is in and then hold.
- **FR-010**: An agent stopped by a limit MUST be recorded with an ending that says so, distinct
  from finishing, being stopped by the reader, crashing, refusing, and running out of room.
- **FR-011**: A limit MUST be acted on at the end of the first turn in which the app sees it has
  been passed. The total shown MUST be what was actually spent, even where that exceeds the limit;
  a figure clamped to the limit MUST NOT be shown.
- **FR-012**: An agent holding because the day's limit was reached MUST be distinguishable from one
  that has reached its own limit, and MUST become able to take a prompt again when the day rolls
  over or the daily limit is raised, without being restarted and without losing its conversation.
- **FR-013**: An agent on a runtime that reports no cost MUST NOT be stopped by a limit, MUST be
  shown as unmeasured wherever its cost would otherwise be, and MUST NOT be presented as being
  within a limit.
- **FR-014**: A workflow fire refused because the day's limit is reached MUST be recorded as a
  refusal with that reason, alongside the refusal reasons the app already records, and MUST NOT
  pause the workflow or alter its schedule.
- **FR-015**: A prompt refused because a limit is reached MUST NOT be silently dropped: the reader
  MUST be told which limit stopped it and what they can do about it.

**Going on anyway**

- **FR-016**: The reader MUST be able to let one agent that has reached the per-agent limit
  continue, and that allowance MUST apply to that agent alone and be visible on it.
- **FR-017**: The reader MUST be able to raise either limit at any time, and raising the daily
  limit MUST make work possible again immediately without a restart.
- **FR-018**: Continuing an agent past its limit and raising a limit MUST both be deliberate acts
  by the reader. Neither MUST happen automatically, and neither MUST be offered as the default
  response to a limit being reached.

**The day**

- **FR-019**: The day MUST be the machine's own local day, and MUST follow the machine's time zone
  when it changes.
- **FR-020**: The day's total MUST include everything spent in that day by every agent in every
  project, including agents started by workflows, agents that have since ended, and agents that
  have been archived.
- **FR-021**: The day's total MUST be derived from what was spent when, so that a restart part-way
  through a day resumes the day's true total rather than starting again from zero, and so that a
  spend reported after the day has rolled over is counted against the day it belongs to.
- **FR-022**: The day's total MUST reset at the day's boundary with no action from the reader.

**Seeing it**

- **FR-023**: Wherever an agent's cost is shown, the app MUST also show how much of the per-agent
  limit is left, when such a limit is set.
- **FR-024**: The app MUST show what the current day has cost and how much of the daily limit is
  left, without the reader opening a page kept for the purpose.
- **FR-025**: A limit that is close to being reached MUST be evident before it is reached, using
  the app's existing rule that colour means a person is needed.
- **FR-026**: Where nothing has been spent in a currency, or no limit is set, the app MUST show
  nothing rather than a zero or an empty limit.
- **FR-027**: An agent stopped by a limit MUST read the same way on the phone as in the window, in
  the same words.

### Key Entities

- **Per-agent limit**: The most any one agent may spend across its whole life. A figure and a
  currency, or nothing. Belongs to the reader, applies to every agent, and is compared against the
  running total the app already keeps for each agent.
- **Daily limit**: The most everything may spend in one local day. A figure and a currency, or
  nothing. The only limit that bounds automation, because automation can produce any number of
  agents that are each within the per-agent limit.
- **Day's total**: What has been spent since the local day began, per currency, across every
  agent including ended and archived ones. Must be recoverable after a restart and must attribute a
  late-arriving figure to the day it was spent in.
- **Allowance**: Permission for one named agent to carry on past the per-agent limit, granted by
  the reader. Belongs to that agent, is visible on it, and changes nothing for any other agent.
- **Stopped by a limit**: An ending, alongside the endings the app already records. The only one
  that means the app itself decided the agent had spent enough. Always arrives at the end of a
  turn, never in the middle of one.
- **Holding**: An agent that has finished its turn and may take no further prompt because the day's
  limit is reached. Distinct from an agent at its own limit, because a new day lifts it and nothing
  the reader does is required.
- **Unmeasured**: An agent whose runtime reports no cost. Neither within a limit nor over one, and
  named as such rather than shown as zero.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a per-agent limit set, no agent's recorded total exceeds that limit by more than
  the cost of one turn, and no agent continues working after its total has passed it.
- **SC-002**: With a daily limit set, the total spent in a day does not exceed it by more than the
  cost of the turns in flight when it was reached, and nothing starts a new turn after it.
- **SC-003**: Every refusal caused by a limit names the limit that caused it. In testing, no
  attempt to start or prompt an agent is refused without a stated reason.
- **SC-004**: A reader who leaves the app running overnight with agents and workflows configured
  finds, next morning, that the day's spend is at or under the limit they set, with no action taken
  by them during the night.
- **SC-005**: The reader can answer *what has today cost* and *how much is left* in one look, from
  a surface they are already on.
- **SC-006**: An agent stopped by a limit is distinguishable at a glance from one that finished,
  one that crashed, and one the reader stopped.
- **SC-007**: Setting either limit for the first time takes under a minute and needs no
  documentation.
- **SC-008**: An agent on a runtime that reports no cost is never described as being within a
  limit; in testing, every surface showing a limit for such an agent says it cannot be measured.
- **SC-009**: Nothing an agent or a workflow does raises or removes a limit. In testing, no
  sequence of agent or workflow actions increases what may be spent.
- **SC-010**: Turning both limits off returns the app to its present behaviour exactly: nothing is
  stopped, nothing is refused, and nothing new is shown.

## Assumptions

- The limits are the reader's and apply across the whole app, not per project. The bill is one bill
  and the request said "per agent and per day", not per project. Per-project budgets were considered
  and left out: they are a second axis that only matters once someone is running several projects
  hard enough for one to crowd out another.
- The per-agent limit is a single figure applying to every agent rather than one set on each agent
  as it starts. A limit that must be set each time is one that will not be set.
- An agent's limit is measured against its whole life, not one turn, matching the running total the
  app already keeps and shows.
- Cost is only ever the runtime's own reported figure. The app does not estimate, does not price
  tokens itself, and does not convert currencies — this is the app's existing rule about cost and
  this feature does not change it. It follows that the app cannot cap what a runtime will not
  report, and the feature says so rather than pretending otherwise.
- Because cost arrives at intervals, and because a turn is never cut short, a limit stops work
  shortly after it is passed rather than exactly at it. Precise capping would require the app to
  price tokens itself and to interrupt an agent part-way — the first is the estimate the app
  deliberately does not make, and the second is what the turn rule exists to prevent. Both limits
  are therefore ceilings with a bounded overshoot, and the app must describe them that way rather
  than promising an exact figure.
- The warning threshold before a limit is reached follows the app's existing threshold for a nearly
  full context rather than introducing a second number for readers to learn.
- Both limits live wherever the app comes to keep the reader's preferences. No settings surface
  exists today, so one is needed; what else goes in it is out of scope here.
- The limit applies to work the app causes. Spend the reader incurs elsewhere with the same
  provider is invisible to the app and is not counted, and the app must not imply that it is.
- Weekly and monthly limits, per-project limits, and per-runtime limits are out of scope. The daily
  limit is the one that bounds an unattended overnight run, which is the failure being guarded
  against.
- Spending history beyond the current day — charts, a ledger, spend by project over time — is out
  of scope. What is kept is whatever is needed to know the current day's total truthfully across a
  restart.
- The feature is macOS-first, matching the app, with the phone showing what it shows rather than
  setting limits.
- The project constitution is currently an unfilled template, so no project-specific principles
  constrain this specification.
