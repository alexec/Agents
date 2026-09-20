# Feature Specification: One Grouping, and Everything Agrees With It

**Feature Branch**: `019-one-grouping`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "Agents are meant to be grouped under the project by status. However, it does seem that agents can end up in the wrong group."

## Overview

Agents sit under their project in four groups, and the whole design of that grouping
rests on one claim: the group is derived, never stored, so an agent cannot be in two
groups or in none. The claim is written twice, in two doc comments, on two different
functions that compute it — and the two do not compute the same thing.

One of them cannot see whether an agent has asked to be looked at, because the fact
lives in the window and the function runs in the daemon. So the daemon counts an agent
as working while the window lists it as needing a person. The badge on a project and the
panel inside it are answering the same question differently.

Two smaller things fall out of the same seam. A project claims someone is wanted on the
strength of an agent that has since stopped, because the check that asks "does anything
here want eyes" never looks at what state those agents are in — while the grouping
deliberately does. And when the app asks a silent agent how its turn went, that question
runs as an ordinary turn, so a finished agent slides into Working and back out again
while the person is not touching anything.

None of this is the grouping rules being wrong. The rules are right. This is every
caller being made to use them, and the facts they depend on being made to reach them.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The count and the list say the same thing (Priority: P1)

A person sees a project that says two agents need them. They open it and find two agents
under Needs attention. The number they were shown outside is the number of rows they
find inside, every time, for every group.

**Why this priority**: A count that disagrees with the list it counts teaches the person
not to trust either. It is the bug that was reported and it is the one that erodes the
project list, which is the first screen in the app.

**Independent Test**: For any project in any state, sum the rows the panel draws under
each heading and compare with the counts the project row shows. They match, including
when an agent has asked to be looked at and not yet been.

**Acceptance Scenarios**:

1. **Given** a project with an agent that has asked the person to look at a file, **When** the project row and the project panel are both drawn, **Then** both place that agent in Needs attention.
2. **Given** the same project, **When** the project row decides whether it needs the person, **Then** it says yes.
3. **Given** any project and any mix of agent states, **When** each group's count is compared with the number of rows under that group's heading, **Then** they are equal.
4. **Given** the person opens the conversation of the agent that asked to be looked at, **When** the panel and the project row redraw, **Then** both move it out of Needs attention together.
5. **Given** the Mac and the phone showing the same project at the same moment, **When** their groups are compared, **Then** every agent is under the same heading on both.

---

### User Story 2 - Nothing is wanted on behalf of an agent that has stopped (Priority: P2)

A project stops claiming somebody is needed once the agent that wanted them is no longer
in a position to want anything. The claim outside the project matches what is inside it.

**Why this priority**: It is a smaller and rarer wrong answer than the count mismatch,
but it is the same failure — a project that says it needs you, opened to find nothing
that does.

**Independent Test**: Put an agent into a state where it has asked to be looked at, stop
it, and confirm the project no longer reports wanting anyone and that nothing appears
under Needs attention.

**Acceptance Scenarios**:

1. **Given** an agent that asked to be looked at and was then stopped, **When** the project is asked whether anything in it wants a person, **Then** it says no.
2. **Given** the same agent, **When** the panel is drawn, **Then** it appears under Stopped and not under Needs attention.
3. **Given** an agent that asked to be looked at and was then archived, **When** the project is asked the same question, **Then** it says no.
4. **Given** the same agent is prompted and starts working again, **When** the project is asked, **Then** the stale claim has not come back.

---

### User Story 3 - The app's own question does not move anything (Priority: P2)

A turn ends without the agent saying how it went. The app asks. The person, who is
looking at the panel, sees nothing move: the agent stays under Complete until it answers,
and then goes where its answer puts it.

**Why this priority**: The panel moving on its own, with no work the person started and
nothing for them to do, is the kind of thing that makes a person doubt what they are
reading. It is also cheap to get right and the rest of the app already draws this
distinction.

**Independent Test**: Let a turn end silently, watch the panel through the whole
question-and-answer round trip, and confirm the agent occupies exactly two positions —
where it started, and where its answer puts it.

**Acceptance Scenarios**:

1. **Given** a turn that ended with nothing said about it, **When** the app asks the agent how it went, **Then** the agent remains under Complete for the whole of that exchange.
2. **Given** the agent answers with an outcome that needs a person, **When** the panel redraws, **Then** it moves to Needs attention, once.
3. **Given** the agent answers with an outcome that needs nobody, **When** the panel redraws, **Then** it has not moved at all.
4. **Given** the person prompts the agent while the app's question is in flight, **When** the panel redraws, **Then** the agent moves to Working, because now there is work they asked for.
5. **Given** the app's question is in flight, **When** the project row's counts are drawn, **Then** they place the agent the same way the panel does.

---

### User Story 4 - There is one grouping, and it cannot be bypassed (Priority: P2)

The next person to draw agents under a heading has one function to call and no second
one to call by mistake. A caller that needs a fact the grouping depends on is given it,
and a caller that cannot supply it cannot silently pass nothing instead.

**Why this priority**: It is what stops this recurring. Two functions is how it happened;
one function with an optional argument that defaults to "no" is how it happened quietly.
But it delivers nothing a person can see on its own.

**Independent Test**: Search for the places an agent's group is decided. There is one.
Attempt to add a caller that computes a group without the full set of facts and confirm
it does not compile or does not pass.

**Acceptance Scenarios**:

1. **Given** the codebase after this feature, **When** somebody searches for where an agent's group is decided, **Then** there is exactly one answer.
2. **Given** a new caller that has no way to know whether an agent has been asked about, **When** it tries to compute a group, **Then** it is made to say so explicitly rather than defaulting to a wrong answer.
3. **Given** a change that adds a fifth reason an agent needs a person, **When** it is added to the one grouping, **Then** every surface picks it up without further change.

---

### Edge Cases

- **A fact the counter cannot know.** Whether an agent has asked to be looked at is known only where a window is open; the thing producing the counts has no window. Either the fact must reach it, or the count must be completed by something that has it. What must not happen is the count quietly reporting as though the answer were no.
- **Two windows, one agent.** If one window has seen the file and another has not, the agent is in different groups in each. This is correct — being looked at is a thing that happens to a person, not to an agent — and the counts each window shows must follow its own window rather than the other's.
- **No window at all.** With nothing open, nothing has asked to be looked at and nothing can be. Groups computed with no window present must be stable and must not flicker when a window opens.
- **An agent that asked to be looked at and then finished.** It still wants eyes. Finishing is not being looked at.
- **An outcome that arrives after the person has already moved on.** A report superseded by the person's own prompt must not pull the agent back into Needs attention.
- **The app's question answered by an agent that then keeps going.** If the agent does more than answer, the turn it is taking is real work and the agent belongs under Working.
- **The app's question that is never answered.** The agent must not be stranded outside its group; it settles back where an unaccounted-for ending belongs.
- **Restarting mid-question.** An agent coming back after a restart must land in the group its state and report say, not in one left over from a question in flight when the daemon went away.

## Requirements *(mandatory)*

### Functional Requirements

#### One grouping

- **FR-001**: There MUST be exactly one place that decides which group an agent is in. No caller may compute a group by any other means.
- **FR-002**: The grouping MUST be total over every combination of the facts it consults, so that an agent is always in exactly one group and never in none.
- **FR-003**: The grouping MUST remain derived from the agent's state and circumstances and MUST NOT be stored on the agent, so that it cannot go stale.
- **FR-004**: A caller that cannot supply one of the facts the grouping depends on MUST be required to say so explicitly, rather than being allowed to omit it and receive the answer for "no".
- **FR-005**: Adding a new reason an agent needs a person MUST require a change in one place only, and MUST be picked up by every surface without further change.

#### Counts and lists agree

- **FR-006**: Every count of agents by group that any surface displays MUST be derived from the same grouping as the list it describes.
- **FR-007**: For any project, the number reported for a group MUST equal the number of agents the panel lists under that group's heading, at every moment both are shown.
- **FR-008**: A project's indication that it needs a person MUST be true exactly when at least one agent in it is in the Needs attention group.
- **FR-009**: Where a count is produced somewhere that cannot know a fact the grouping depends on, that count MUST be completed by something that does know it before any person sees it.
- **FR-010**: The Mac and the phone MUST place every agent under the same heading for the same project at the same moment.

#### Wanting a person

- **FR-011**: A project MUST report that something in it wants a person only on the strength of agents whose state allows them to want one, using the same rule the grouping uses.
- **FR-012**: An agent that asked to be looked at and has since been stopped or archived MUST NOT cause its project to report wanting a person.
- **FR-013**: Being looked at MUST clear the claim, and MUST clear it for the count and the list together.

#### The app's own question

- **FR-014**: A turn started by the app's own question about how a turn went MUST NOT change which group the agent is in for the duration of that exchange.
- **FR-015**: An agent under that question MUST move group only once, when its answer settles, and MUST move to the group its answer implies.
- **FR-016**: A prompt from the person, arriving while the app's question is in flight, MUST move the agent to Working, because that work was asked for.
- **FR-017**: An agent that never answers the app's question MUST settle in the group an unaccounted-for ending belongs in, and MUST NOT remain outside the groups.
- **FR-018**: The distinction between the app's own turn and the person's MUST be drawn from the same fact the rest of the app already uses for it, not from a second one introduced here.

#### Keeping it

- **FR-019**: A test MUST exhaust every combination of the facts the grouping consults and assert the group for each, so that a case added later cannot fall through unnoticed.
- **FR-020**: A test MUST assert that counts and lists agree, for a project holding an agent in each group including one that has asked to be looked at.
- **FR-021**: A check MUST fail when a second implementation of the grouping is introduced.
- **FR-022**: The group headings, their order, and which of them are shown by default MUST be unchanged by this feature.

### Key Entities

- **Group**: One of the four headings an agent is listed under, plus the archived one shown on request. Derived, never stored.
- **The facts the grouping consults**: What state the agent is in, whether it has asked to be looked at and not been, and what it said about how its last turn went. This feature does not add to the list; it makes the list reach every caller.
- **Wanting a person**: The single idea behind the Needs attention group and behind a project's claim that it needs somebody. One rule, asked in two places.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The number of implementations that decide an agent's group is exactly one. It is two today.
- **SC-002**: For every project and every group, the displayed count equals the number of rows listed. There is at least one reachable case where it does not today.
- **SC-003**: A project indicates it needs a person exactly when opening it reveals an agent under Needs attention — with no false positives and no false negatives.
- **SC-004**: Watching the panel through a silent ending and the app's question that follows, an agent changes group at most once, and only when its answer settles.
- **SC-005**: The same project compared on Mac and phone at the same moment shows every agent under the same heading.
- **SC-006**: A test exhausts every combination of facts the grouping consults; adding a fact without extending the test fails the build.
- **SC-007**: Introducing a second way to compute a group causes a test to fail, named and located.
- **SC-008**: No agent, in any reachable combination of state, report and attention, is in no group.

## Assumptions

- The grouping rules themselves are correct and are not revisited. Which group each combination of facts belongs to is already decided and this feature does not change any of those decisions. Only who computes them, and with what, changes.
- An agent under the app's own outcome question stays under Complete. This was chosen over moving it to Working and over giving it a heading of its own: the turn is real and costs money, but it is work the person did not ask for and lasts seconds, and a panel that rearranges itself unbidden is worse than one that is briefly incomplete.
- Whether an agent has asked to be looked at remains window-scoped and is not stored by the daemon. The fix is to get the fact to the count, not to persist it — persisting it would make it outlive the window it belongs to.
- Two windows legitimately disagreeing about one agent is correct behaviour, not a bug to be designed out.
- The existing headings, their wording and their order are right. This feature changes placement, not presentation.
- This is independent of 018 visual-consistency. 018 changes how a group is drawn; this changes which group an agent is in. They touch the same screens and neither depends on the other.
