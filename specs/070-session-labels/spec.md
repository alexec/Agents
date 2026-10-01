# Feature Specification: Session labels

**Feature Branch**: `agents/speckit-specify-github-issue`

**Created**: 2026-09-29

**Status**: Draft

**Input**: Issue #50, "Session labels: tags the person and agents can put on sessions".

## Why this feature exists

A session card shows a title, a runtime, a status and the last thing its agent said. That
is enough to recognise a chat you were in five minutes ago, and not enough to recognise one
you left running an hour ago. People already name sessions out loud: "the perf one", "the
one for 42", "the spike". A label puts that name where the work is.

The person and an agent have different standing here, and the app keeps them apart. A label
belongs to whoever put it there. The person can add and remove any label, theirs or an
agent's. An agent can add its own, and take away only its own. The app enforces the rule
itself rather than asking the agent to, so an agent that tries to take a person's label is
refused and told why.

Labels travel with the session. They show on the card, in the chat header, and in what an
agent sees when it lists the project's sessions, so a session can be found by what it is
rather than by what it is called.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Tell a session apart at a glance (Priority: P1)

Alex has four Claude sessions running on one project. He labels them `perf`, `#42` and
`spike` when he starts them, from the new-session form or the card's menu, and the card
carries the chip from the moment it appears. On the phone the same chips show, fewer of
them, with a count for the rest.

**Why this priority**: This is the whole point of the feature. Without a label on the card
there is nothing to tell apart, and the other stories only add labels nobody can see.

**Independent Test**: Start three sessions and give each a label, one from the new-session
form and two from the card's menu. The chips appear on the Mac's cards and rows, in each
chat's header, and on the phone's card. Remove one label and it goes from all three places.

**Acceptance Scenarios**:

1. **Given** a new session form, **when** Alex types `perf` as a label and starts the
   session, **then** the card carries a `perf` chip from its first moment, and the chat
   header carries it too.
2. **Given** a session with no labels, **when** Alex adds one from the card's menu, **then**
   the chip appears on the card, the row and the header without the session being reopened.
3. **Given** a session with a label, **when** Alex removes it from the chat header, **then**
   the chip goes from the card, the row and the header.
4. **Given** a label an agent added, **when** Alex removes it, **then** it goes, and the
   agent is not told anything.
5. **Given** the same project on the phone, **when** Alex opens a session's card, **then**
   its labels show as chips, showing at most two and a `+N` for the rest.

---

### User Story 2 - An agent labels the work it starts and the work it finishes (Priority: P1)

An agent that starts three helpers for one piece of work labels them as it goes, so Alex can
see which is which without opening each one. The agent labels its own session at the end of
a turn, when it knows what the turn turned out to be. A workflow labels the agents it starts,
so a nightly run's sessions are already marked when they appear.

**Why this priority**: Half the sessions in a busy project are agents' helpers, and nobody
but the agent knows what each one was for. This makes the labels true without Alex typing
them.

**Independent Test**: Have an agent start a helper with labels, have another agent add a
label in its `finish_turn`, and run a workflow with labels in its file. All three show up as
agent-owned chips on the card and in the session list.

**Acceptance Scenarios**:

1. **Given** an agent starting a helper, **when** it passes labels, **then** the helper's
   card carries them as the agent's own chips from the moment it appears.
2. **Given** an agent ending a turn, **when** it adds a label in `finish_turn`, **then** the
   chip is on the card before Alex next looks at it.
3. **Given** an agent that added a label itself, **when** it removes that label in a later
   `finish_turn`, **then** the chip goes.
4. **Given** a workflow whose file sets labels, **when** the workflow starts an agent, **then**
   that agent carries them, and every agent the run starts carries the same ones.
5. **Given** a label an agent added, **when** the person looks at the card, **then** the
   chip is drawn differently from one the person added, with no legend needed to tell.

---

### User Story 3 - The person stays in charge of their own labels (Priority: P2)

Alex labels a session `urgent` himself. An agent working on that session tries to clean up
and removes `urgent`. The label stays, the chip stays filled, and the agent is told it may
not remove a label the person added. The app holds the rule itself, so it stands whatever the
agent's prompt says.

**Why this priority**: Ownership is what makes labels trustworthy. Without it, an agent can
quietly rewrite the person's own words for a session.

**Independent Test**: Add a label as the person, then have an agent try to remove it, try
to rename it, and try to add it as its own. The person's label survives all three, and the
agent gets a reason each time.

**Acceptance Scenarios**:

1. **Given** a label the person added, **when** an agent asks to remove it, **then** nothing
   changes and the agent is told the label is the person's.
2. **Given** a label the person added, **when** an agent asks to remove it by a different
   spelling, **then** nothing changes, for the same reason.
3. **Given** a label the person already has on a session, **when** an agent adds the same
   label, **then** the label stays the person's, shown once, and the agent is told so.
4. **Given** a label an agent added, **when** the person removes it, **then** it goes.
5. **Given** an agent tries to remove a person's label, **when** the person reads the
   conversation afterwards, **then** the refusal is visible in what the agent said.

---

### User Story 4 - Find a session by what it is (Priority: P2)

Alex wants the `perf` session, not whichever one Claude is on. He filters the sessions
column by label, and the list narrows. An agent looking for a session to carry on from finds
it the same way, because the labels are in what `list_sessions` gives it.

**Why this priority**: Labels that cannot be searched for are decoration. This is what turns
them into a way to find work.

**Independent Test**: Label four sessions `perf` and ten others differently, filter by
`label:perf`, and check that exactly the four show. Then read what an agent gets from
`list_sessions` and find one of the four by its label.

**Acceptance Scenarios**:

1. **Given** sessions with and without labels, **when** Alex filters the sessions column by
   `label:perf`, **then** only the sessions carrying `perf` are listed.
2. **Given** a label filter in use, **when** Alex types text as well, **then** both apply,
   and only sessions matching both are listed.
3. **Given** a filter for a label no session has, **then** the list is empty and says the
   label matched nothing, rather than showing every session.
4. **Given** an agent listing the project's sessions, **when** it reads the list, **then**
   each session's labels and who owns them are in it.
5. **Given** a label written `Perf` on one session and `perf` on another, **when** Alex
   filters by either, **then** both sessions are listed.

---

### Edge Cases

- A sixth label on a session: refused, with a reason, and the five already there are
  untouched.
- A label of only spaces, or longer than 24 characters: refused, with a reason.
- `Perf`, `perf` and ` PERF ` are one label everywhere, and the first spelling used in the
  project is the one shown.
- A label an agent added, which the person then removed, which the agent adds again in its
  next `finish_turn`: it comes back as the agent's own, which is what the agent is entitled
  to.
- A label added to a session while its turn is running: it shows on the card at once, and
  the turn in progress is not disturbed.
- A label removed from the last session that carried it: it leaves the project's list, so
  the menu stops suggesting it. It can be typed again.
- A session is archived with labels, and later brought back: the same session still has
  those labels.
- A new chat that reads an older session's history starts without that session's labels;
  the person or its agent may label the new chat separately.
- A workflow is stopped or its agent is archived: the labels on its sessions stay, since the
  sessions do.
- A project is deleted: its labels go with it. The same label in another project is that
  project's own label, with its own owner.
- A server project: labels are set and read on the server from the Mac. In this version,
  iPhone and iPad show Mac projects only, as specified by feature 037.
- A label that looks like a number, such as `#42`, is a label like any other and is not read
  as an issue reference.

## Requirements *(mandatory)*

### Functional Requirements

**What a label is**

- **FR-001**: A session MAY carry up to 5 labels. A sixth is refused, with a reason, and
  changes nothing.
- **FR-002**: A label MUST be 1 to 24 characters, and MUST NOT be only spaces. Spaces at
  either end do not count and are not shown.
- **FR-003**: Labels are compared without regard to case, and a project holds one label
  however it is spelled. The spelling first used in the project is the one shown.
- **FR-004**: Labels are shared per project. The places labels are added MUST suggest the
  labels already in use in that project, so a typo does not become a second label.
- **FR-005**: Every label has exactly one owner: the person, or the agent whose session
  carries it. A helper owns labels supplied when it starts. The owner is kept with the
  label, wherever the label is shown.
- **FR-006**: A person's label and an agent's label MUST be told apart at a glance wherever
  a label is shown, without a legend: a filled chip for the person's, an outlined chip for
  an agent's. Colour alone does not carry this.
- **FR-007**: A label is extra information about a session, and MUST NOT replace its title.
  Naming a conversation still works as it does today.

**The person labelling a session**

- **FR-008**: The person MUST be able to add a label to a session from the new-session form,
  the session's menu, and the chat header, on the Mac, the iPhone and the iPad.
- **FR-009**: The person MUST be able to remove any label from a session, their own or an
  agent's, from the same places, on all three devices.
- **FR-010**: Where labels are added, the app MUST show the project's labels in use as
  suggestions, and MUST show which of them the session already has.
- **FR-011**: The person MUST be able to remove a label they have just added, in the same
  place they added it, without the card reloading.
- **FR-012**: A label the person added MUST stay the person's, whatever an agent does with
  it afterwards.

**Agents and workflows labelling**

- **FR-013**: `start_agent` MUST accept labels, applied as the helper's own labels when
  it starts.
- **FR-014**: `finish_turn` MUST accept a label change, with labels to add and labels to
  remove, applied when the turn ends.
- **FR-015**: A workflow's file MUST be able to set labels, applied to every agent the run
  starts. Such a label is owned by the agent the workflow started, and is shown as an
  agent's.
- **FR-016**: An agent MUST be able to add any label the rules allow, and MUST be able to
  remove only a label an agent added.
- **FR-017**: The app MUST enforce the ownership rule itself, not leave it to the agent's
  prompt. A call that removes or renames a person's label MUST change nothing and MUST
  return a reason the agent can act on.
- **FR-018**: When an agent adds a label the person already has on that session, nothing
  changes, the label stays the person's, shown once, and the agent is told so.
- **FR-019**: An agent's label change MUST be applied whether the agent was started by the
  person, by another agent, or by a workflow.

**Where labels show**

- **FR-020**: A session's labels MUST show as chips on its card and its row, and in its chat
  header, on the Mac, the iPhone and the iPad.
- **FR-021**: On a phone card, at most 2 chips show and the rest are counted as `+N`. The
  chat header shows all of them.
- **FR-022**: `list_sessions` and `list_my_agents` MUST report each session's labels and
  their owners, so an agent can find a session by label.
- **FR-023**: A label added or removed MUST appear on every device showing that session,
  without the person reopening it.

**Finding a session**

- **FR-024**: The person MUST be able to filter the sessions list by label, by name, on the
  Mac and on the phone.
- **FR-025**: A label filter and the text search MUST combine, and only sessions matching
  both are listed.
- **FR-026**: Filtering by a label no session has MUST show an empty list that says the
  label matched nothing, not the whole list.

**Keeping labels**

- **FR-027**: Labels are kept with the session. They MUST reach the phone for Mac projects
  and the Mac for server projects. Phone access to server projects is outside this feature.
- **FR-028**: Labels MUST survive archiving. A session brought back has the labels it had.
- **FR-029**: A label on no session in the project is no longer suggested, and MAY be typed
  again to start a new one.

### Key Entities

- **Session label**: a short tag on one session, owned by the person or that session's agent.
  Compared without regard to case; the project keeps the spelling first used.
- **Project label list**: the labels in use across a project's sessions, offered as
  suggestions wherever a label is added. A project's list is its own, and is not shared with
  another project.
- **Label change**: an addition or a removal asked for by the person, an agent or a
  workflow, with the owner it may act on and what happens when the owner does not allow it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Alex can add a label to any session in under 10 seconds from the sessions
  list, without opening the session, on the Mac; Mac-project sessions can also be labelled
  on the phone.
- **SC-002**: Every label an agent adds, through `start_agent`, `finish_turn` or a workflow,
  is on the card and in the session list within 5 seconds of the call, on the Mac for
  local and server projects and on the phone for Mac projects.
- **SC-003**: Across 20 attempts by an agent to remove or rename a person's label, 0
  labels change, and all 20 calls return a reason.
- **SC-004**: A label both the person and an agent have added to one session is shown once,
  as the person's, in every place it appears.
- **SC-005**: Filtering by a label shows exactly the sessions carrying it, out of a project
  of 200 sessions, within 1 second of choosing the filter.
- **SC-006**: In a project's use, `Perf`, `perf` and ` PERF ` are never two labels, and no
  two labels differ only in case.
- **SC-007**: No chip is ever cut off mid-word, on the Mac or the phone. A phone card shows
  at most 2 chips and a `+N`.
- **SC-008**: Archiving a session and bringing it back leaves its labels exactly as they
  were. A separate chat that reads its history starts with no labels.

## Docs *(mandatory)*

- `docs/reference/agent-tools.md`: change the `finish_turn` row for the label change, the
  `start_agent` row for labels, and the `list_sessions` and `list_my_agents` rows for the
  labels and owners they report.
- `docs/how-to/label-a-session.md`: add. Adding, removing and filtering labels, and what an
  agent may and may not do with them.
- `docs/reference/workflows.md`: change, for the labels a workflow's file can set.
- `docs/reference/statuses.md`: change, for where labels sit on a card and a row, and that
  they survive archiving.
- `docs/how-to/archive-park-stop.md`: change, to say labels stay with an archived session.

## Wireframes

The Mac card, row, chat header, new-session form and label menu, and the phone's card,
header and menu, are in [wireframe.md](wireframe.md).

## Assumptions

- The decisions issue #50 left open are made as follows, and `/speckit-clarify` can change
  any of them: labels are one shared list per project and are compared without regard to
  case; labels survive archiving but a separate chat does not inherit them;
  a session carries at most 5 labels of at most 24 characters, and a phone card shows 2 and
  counts the rest.
- Colour is per owner, not per label: the person's chip is filled, the agent's outlined, and
  both use the same two colours so a card does not become a colour chart.
- Labels are per project, not per person or per Mac. Two projects may each have a `perf`.
- The phone retains feature 037's Mac-project scope; server projects are managed from
  the Mac in this version.
- A label is free text and is not linked to anything, so `#42` does not turn into a link to
  issue 42.
- Reading another session's history (065) does not create a successor link. The new chat
  has its own labels.
- Nothing about the runtime, the permission mode or the work itself changes because a
  session is labelled.
- Filter by label and filter by text are the only two ways to narrow the sessions list; no
  saved views or label groups are part of this.
