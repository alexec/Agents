# Feature Specification: One Suggested Prompt

**Feature Branch**: `031-single-suggested-prompt`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Remove support for multiple suggested prompts. Only one suggested prompt."

## Why this feature exists

At the end of a turn an agent may offer what the person might say next. Today it offers two to
four. On the Mac the first sits in the empty prompt field as placeholder text, and the arrow keys
step through the rest, which nobody can see until they press a key they have no reason to press.
On the phone they are a row of chips that scrolls sideways, because four sentences do not fit.

Several suggestions ask the agent to pad and the person to choose. The first is almost always the
one that matters; the others are filler the agent was told to produce because the tool said "two
to four". And the Mac has already shown the honest shape of this: one line, written where the
answer goes, taken with Tab.

So an agent offers at most one thing to say next. It is the best next step, the one it would have
put first. Every surface shows that one, and nothing about the app implies there are more.

The one thing this must not break is a conversation already under way. The briefing is sent once
and lives in the runtime's history, so a conversation briefed before this change and resumed after
it will still send a list. That must keep working: the first entry is kept, the rest are dropped,
and nothing is refused.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The agent offers one next step (Priority: P1)

An agent finishes a piece of work and ends its turn. With it, it offers one thing the person might
say next: the obvious next step. It is not asked for more, and the app would not show more if it
sent them.

**Why this priority**: This is the change. Every other story is how the one suggestion is shown.

**Independent Test**: Start a fresh conversation, let the agent finish a turn, and confirm the end
of the turn carried at most one suggestion, and that what the agent was told asks for one.

**Acceptance Scenarios**:

1. **Given** a fresh conversation, **When** the agent ends a turn with a suggestion, **Then** the
   conversation holds exactly one suggested prompt.
2. **Given** what the agent is told at the start of a conversation and in the end-of-turn tool,
   **When** it is read, **Then** it asks for one next thing, never "two to four", and nothing in it
   describes buttons, a row or a list.
3. **Given** an agent that ends its turn with no suggestion, **When** the turn ends, **Then**
   nothing is suggested, as today.

---

### User Story 2 - The Mac shows the one, and only the one (Priority: P1)

The person comes back to a finished conversation on the Mac. The empty prompt field shows the
agent's suggestion where their words would go. Tab takes it into the field without sending it.
Escape puts it away until the next turn ends. The up and down arrows do nothing to it, because
there is nothing to step to.

**Why this priority**: The Mac is where most turns are read and answered. Leaving the arrow keys
cycling through a list of one would be a dead gesture left in place.

**Independent Test**: With a conversation holding one suggestion, confirm the field shows it, Tab
fills the field with it unsent, Escape hides it, and the arrow keys leave it unchanged.

**Acceptance Scenarios**:

1. **Given** a finished turn with a suggestion and an empty field, **When** the person looks at the
   prompt, **Then** the suggestion is shown in the field as its placeholder.
2. **Given** the suggestion showing, **When** the person presses Tab, **Then** the field holds the
   suggestion's words, focused and unsent.
3. **Given** the suggestion showing, **When** the person presses the up or down arrow, **Then** the
   suggestion does not change and the key does whatever it would do in an empty field with nothing
   suggested.
4. **Given** the suggestion showing, **When** the person presses Escape, **Then** it is hidden
   until the next turn ends, as today.
5. **Given** the person has typed anything, **When** they look at the field, **Then** no suggestion
   is shown behind their words, as today.

---

### User Story 3 - The phone shows one chip (Priority: P2)

On the phone, a finished conversation with a suggestion shows it as a single chip above the prompt.
Tapping it fills the field, unsent. There is no sideways-scrolling row, because there is nothing to
scroll to.

**Why this priority**: Same change, second surface. The phone is where the person answers away
from the desk, and a scroller holding one chip reads as broken.

**Independent Test**: With a conversation holding one suggestion, open it on the phone and confirm
one chip shows above an empty prompt, and tapping it fills the field without sending.

**Acceptance Scenarios**:

1. **Given** a conversation holding one suggestion, **When** it is opened on the phone with an
   empty field, **Then** exactly one chip is shown above the prompt, with its short label.
2. **Given** that chip, **When** it is tapped, **Then** the field holds the suggestion's words,
   unsent.
3. **Given** a suggestion whose label is long, **When** it is shown, **Then** it is shortened to
   fit the width rather than scrolling off it.

---

### User Story 4 - A conversation begun before this still works (Priority: P2)

A conversation was briefed before this change, when agents were told to offer two to four. It is
resumed after. Its agent ends a turn with three suggestions. The app keeps the first, shows it
like any other, and does not refuse the call or lose the outcome that came with it.

A conversation saved with several suggestions shows its first one when the app next opens it.

**Why this priority**: A resumed conversation that loses its outcome because of a list it was
told to send would be a regression the person cannot fix.

**Independent Test**: End a turn through either end-of-turn tool with three suggestions and
confirm the outcome lands and exactly the first suggestion is kept. Open a stored conversation
holding several suggestions and confirm only the first is shown.

**Acceptance Scenarios**:

1. **Given** an end-of-turn call carrying several suggestions, **When** it is received, **Then**
   the outcome, message and title land as they would otherwise, and only the first suggestion is
   kept.
2. **Given** a call through the older suggestions-only tool name carrying several, **When** it is
   received, **Then** it succeeds and only the first is kept.
3. **Given** a conversation stored with several suggestions, **When** it is loaded, **Then** it
   holds only the first.
4. **Given** a list whose first entry is empty or unusable, **When** it is received, **Then** the
   first usable entry is kept, as blank entries are dropped today.

### Edge Cases

- An agent sends one suggestion in the new single form and a list in the old form in the same call:
  the single form wins.
- The phone is running a build from before this change against a daemon from after it: it receives
  a list of at most one and shows one chip.
- A phone from after this change against a daemon from before it: it receives up to four and shows
  the first.
- A suggestion arrives while the person has already typed: nothing is shown, as today.
- The turn that carried the suggestion is followed by another prompt: the suggestion is cleared, as
  today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A conversation MUST hold at most one suggested prompt at any time.
- **FR-002**: The end-of-turn tool MUST ask the agent for at most one next prompt, described as the
  single best next step, and MUST NOT mention two to four, buttons, or a row.
- **FR-003**: The briefing sent at the start of a conversation MUST ask for one next thing rather
  than "two to four things".
- **FR-004**: The app MUST accept end-of-turn calls, through the current and older tool names, that
  carry several suggestions, keeping only the first usable one and never refusing the call or
  dropping its outcome because of the count.
- **FR-005**: When a call carries both a single suggestion and a list, the single suggestion MUST be
  kept.
- **FR-006**: A conversation stored with several suggestions MUST load holding only the first.
- **FR-007**: On the Mac, the suggestion MUST be shown as the empty field's placeholder, taken with
  Tab, and dismissed with Escape, as today.
- **FR-008**: On the Mac, the up and down arrow keys MUST NOT act on the suggestion.
- **FR-009**: On the phone, the suggestion MUST be shown as a single chip above the prompt, not in a
  scrolling row, and a long label MUST be shortened to fit.
- **FR-010**: Taking a suggestion on any surface MUST fill the field without sending, as today.
- **FR-011**: Every existing rule about when a suggestion shows and when it clears — only while the
  field is empty, cleared when the next prompt goes, hidden by Escape until the next turn ends —
  MUST be unchanged.
- **FR-012**: The phone and the daemon MUST keep understanding each other across one side being
  updated before the other.

### Key Entities

- **Suggested prompt**: What the agent thinks the person might say next. A short label for a chip
  and the fuller words that go into the field. A conversation has none or one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a fresh conversation, 100% of turn endings carry zero or one suggestion.
- **SC-002**: No surface — Mac field, phone prompt — ever shows more than one suggestion or offers a
  way to step to another.
- **SC-003**: A turn ended with four suggestions in the old form lands its outcome and shows exactly
  its first suggestion, every time.
- **SC-004**: Nothing the agent is told at the start of a conversation or in the tool it ends with
  asks for more than one next prompt.
- **SC-005**: The person can take the suggestion in one action (Tab on the Mac, one tap on the
  phone), unchanged from today.

## Assumptions

- The suggestion keeps both its short label and its fuller words. The Mac field shows the words;
  the phone chip needs the label to fit.
- "The first" is the one to keep, because agents were told to put the best first.
- The older suggestions-only tool name stays accepted, as 023 left it, and follows the same
  keep-the-first rule. Removing it is not part of this.
- The Mac keeps the placeholder presentation; only the stepping between suggestions goes. The
  phone moves from a scrolling row to one chip, the smallest change that shows one.
- Tests that assert on counts of two or more suggestions change to assert on one; tests that send
  several stay, as proof that the old form is still accepted.
- The live-run evidence that agents follow the briefing (023, 014) is not re-run as part of this
  spec's gate; a live run confirming one suggestion per turn is a follow-up for Alex.
