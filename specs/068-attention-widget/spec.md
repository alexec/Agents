# Feature Specification: Attention on the Home screen

**Feature Branch**: `agents/work-github-issue-33`

**Created**: 2026-09-29

**Status**: Draft

**Input**: Issue #33, "Add an iOS widget for agent sessions needing attention".

## Why this feature exists

The phone can answer an agent from anywhere, and when an agent wants you the Mac sends you
a banner (021). But a banner is a moment. It arrives, and if you were not looking at the
screen it is gone, and the only way to find out what is still waiting is to open the app and
read the projects list one row at a time — a list whose only signal that anything wants you
is a small orange dot beside a folder you may not remember starting work in.

A widget puts the number where you look without being asked for it, and a tap on it takes
you to the conversation rather than to the list. Nothing new is being measured here: this
shows the same count the Mac already puts on its Dock icon, and it opens the same
conversation a banner opens (FR-001).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See what is waiting without opening the app (Priority: P1)

Someone working with agents leaves the phone face up on a desk and gets on with something
else. Two agents finish and both want an answer. Without leaving what they are doing they
glance at the Home screen and see that two sessions need them, and in the larger widget
they read which two: the project each is in, the agent's title, and what it is asking for.

**Why this priority**: It is the whole of issue 33. A widget that shows a number and a
widget that shows a number *and* what the number is about are the same feature at two sizes;
without either there is nothing to ship.

**Independent Test**: Put the widget on a Home screen with two agents waiting on you and
one working, and look at it. The small one shows 2; the medium one shows 2 and names both
waiting agents with their project and what they are asking for, and does not name the
working one.

**Acceptance Scenarios**:

1. **Given** two sessions need a person and three are working, **When** the small widget
   is looked at, **then** it shows the number 2, in the same colour the app uses for a
   session that needs you.
2. **Given** two sessions need a person, **When** the medium widget is looked at, **then**
   it shows the number 2 and one row for each of the two, each naming the project, the
   agent's title and what is being asked for.
3. **Given** more sessions need a person than there are rows, **When** the medium widget is
   looked at, **then** it shows the newest ones, never more than it has rows for, and says
   how many are not shown.
4. **Given** one session is waiting on a question and another has finished unread, **When**
   the medium widget is looked at, **then** both are rows, and the finished one's row says
   it finished rather than inventing a question for it.
5. **Given** nothing needs a person, **When** the widget is looked at, **then** it says so
   plainly, and shows no rows.
6. **Given** the app has never been opened since it was installed, **When** the widget is
   looked at, **then** it says it does not know yet and does not show a number.

---

### User Story 2 - Tap it and be in the conversation (Priority: P1)

Someone sees two sessions waiting and taps the first row. The app opens on that agent's
conversation, in that agent's project, with the question on screen and ready to answer.
Tapping the small widget — which has no rows — takes them to the newest thing waiting,
which is the same place a banner would have taken them.

**Why this priority**: A widget that cannot be acted on is a decoration. The tap is what
makes the glance worth having, and the destination has to be the conversation: opening the
projects list and making the reader find the row is the work this feature exists to remove.

**Independent Test**: With the app not running, tap a medium row naming an agent. The app
opens on that agent's conversation in that agent's project, in the right project even
though a different one was open last.

**Acceptance Scenarios**:

1. **Given** the app is not running, **When** a row naming an agent is tapped, **then** the
   app opens on that agent's conversation, in that agent's project.
2. **Given** the app is not running and the tap arrives before the Mac has answered, **When**
   the agents arrive, **then** the conversation opens anyway, without a second tap.
3. **Given** the small widget, **When** it is tapped, **then** the newest session waiting
   is opened, or the app opens with nothing selected when nothing is waiting.
4. **Given** the agent in the tapped row was archived or stopped since the widget was last
   drawn, **When** the app opens, **then** it shows what it can about that conversation and
   does not sit on a blank screen.
5. **Given** a tap opens a conversation, **When** the person backs out of it, **then** they
   are in the project the conversation belongs to.

---

### User Story 3 - Be right without being asked (Priority: P2)

Someone is away from the phone all afternoon. An agent raises a question at four o'clock and
the Mac sends the silent push that wakes the app (021 T079). By the time they look at the
Home screen the widget says one, without them having opened the app. And when they look at a
widget whose number has not been updated in hours, it does not claim the number is current.

**Why this priority**: Without this the widget shows a number from whenever the app was last
open, which is worse than no widget: it looks live and is not. It is second because the
first two stories are already worth having on their own.

**Independent Test**: With the app in the background, have a need raised on the Mac and
wait for the silent push; the widget's number changes without the app being brought to the
front. Then write a stale snapshot by hand and look: the widget says how old the number is.

**Acceptance Scenarios**:

1. **Given** the app is in the background or not running, **When** a need is raised and the
   Mac's silent push arrives, **Then** the widget's number changes without the app being
   opened.
2. **Given** a need is answered or withdrawn on another surface, **When** the app next
   updates, **Then** the widget's number drops accordingly.
3. **Given** the widget's number is more than a few minutes old, **When** it is looked at,
   **Then** it says how old it is.
4. **Given** the app cannot reach the Mac, **When** the widget is looked at, **Then** it
   shows the last number it was given rather than a zero, and its age.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The widget's number MUST be the number of sessions needing attention, computed
  by the same rule the Mac's Dock badge uses (Needs attention and Blocked, across live
  projects). The two MUST agree whenever they are drawn from the same state.
- **FR-002**: The widget MUST offer a small and a medium layout, and no other.
- **FR-003**: The small widget MUST show the number, and MUST be in the attention colour
  whenever the number is not zero.
- **FR-004**: The medium widget MUST show the number and one row per waiting session, each
  row naming the project, the agent's title, and what is being asked for where something is.
- **FR-005**: A row MUST never name a session that is not waiting for a person, and MUST
  never name a waiting session twice when it has raised more than one question.
- **FR-006**: The widget MUST show no more rows than it has room for, and MUST say how many
  sessions it is not showing.
- **FR-007**: A session with nothing pending and a finished session MUST be described by
  what is true of them — that they finished, that they need you — and MUST NOT be given a
  question they did not ask.
- **FR-008**: With nothing waiting, the widget MUST say so in words and MUST NOT show rows.
- **FR-009**: With no information at all (the app has never run since install), the widget
  MUST say it does not know yet and MUST NOT show a number.
- **FR-010**: Tapping the small widget MUST open the app on the newest session waiting, or
  on nothing when nothing is waiting.
- **FR-011**: Tapping a row MUST open that session's conversation, in that session's
  project.
- **FR-012**: A tap that arrives before the work has been fetched MUST open the
  conversation once it arrives, without a second tap.
- **FR-013**: A tap naming a session that no longer exists MUST NOT leave the app on an
  empty screen; it MUST show what the app can about that session.
- **FR-014**: The widget MUST NOT reach the Mac, hold a pairing key, open a connection, or
  answer anything. It shows what it has been given and nothing else.
- **FR-015**: Nothing the widget shows may outlive the device: it is written by the app into
  the pair's own shared storage on that device, holds no account, no address and no key, and
  is removed when the app is removed.
- **FR-016**: The number MUST be updated when the app is brought to the front, when a need
  changes while it is connected, and when the silent push for a need arrives while it is
  not.
- **FR-017**: The widget MUST NOT present a number as current when it is not: a snapshot
  older than a few minutes MUST show its age.
- **FR-018**: A failure to write or read the number MUST leave the app and the widget
  working as they did before, with no error shown to the person.
- **FR-019**: Every surface that says what needs you — the widget, the project's row, the
  Dock badge — MUST use the one rule for "needs you" that the app already has. A new
  definition of it MUST NOT be introduced here.

### Key Entities

- **Attention snapshot**: what the widget is shown — when it was written, how many sessions
  need a person in total, and the sessions named for the rows (which one, which project,
  what it is called, what it is asking for, and when it was raised). A device-local copy,
  written by the app and read by the widget; nothing in it is the state of the work itself.
- **Waiting session**: one agent conversation that needs a person, as the app already groups
  it. Identified by the agent, so two questions from one agent are one row.
- **Attention link**: a name for a destination, either "whatever needs you" or one named
  conversation, in the one form the app and the widget both understand.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The number on the widget equals the number on the Mac's Dock badge in 100% of
  trials where both are drawn from the same state.
- **SC-002**: In 100% of trials, a tap on a row opens the conversation that row names, in
  that conversation's project, with no further tap needed.
- **SC-003**: A need raised while the app is in the background changes the widget's number
  within one minute of the Mac's push arriving, in 9 of 10 trials.
- **SC-004**: The widget is added to a Home screen and the app is not opened for a whole
  working day; it never shows a number with no rows behind it, and never claims a number is
  current when it is not.
- **SC-005**: With the app never run since install, the widget shows no number at all in
  100% of trials.
- **SC-006**: Adding the widget changes nothing about what the app shows, what it does, or
  what the daemon holds, verified by the app's own tests passing unchanged.

## Docs *(mandatory)*

- `docs/how-to/see-what-needs-you-from-your-home-screen.md` — add: putting the widget on a
  Home screen, what each size shows, what a tap opens, and when the number is last refreshed.
- `docs/explanation/phone-and-ipad.md` — change: a short section on the widget as a device-local
  copy of a number, next to what the phone does and does not do.

## Assumptions

- The person uses one iPhone or iPad of their own, as 021 assumes, and the widget is added
  by hand to their own Home screen; the app never adds it for them.
- The rule for when a session needs a person is the one the app already has and is reused
  unchanged. This feature detects nothing and defines nothing new.
- The Mac sends the silent push for a need while the person is away (021 T079), and that
  push is what refreshes the number without the app being opened. Where no push arrives —
  the person is at the Mac, so the device is not treated as away — the number is as fresh as
  the app's own last look, and says so.
- One rule for "needs you" means the widget can never disagree with the Dock badge or the
  project row, because all three read the same grouping.
- The widget is a view, not a surface: it holds nothing and answers nothing. 021 put acting
  on a notification out of scope, and this feature keeps that boundary.

## Out of Scope

- Lock Screen, StandBy and any other widget family. Small and medium on the Home screen are
  what was asked for; the others are a later feature if they are wanted.
- Answering a question, granting a permission or any other action from the widget.
- Choosing the widget's contents, layout or colour. What it shows is what it shows.
- More than one widget, or a configurable set of numbers (spending, working, and so on).
- The Mac writing the number itself, so that a need raised at the Mac reaches a device
  immediately without the app being opened. The machinery for it is the mailbox the phone
  already has; it is a separate feature.
- Anything about servers (037). A session in a server project is not on the phone today and
  is not on the widget.
