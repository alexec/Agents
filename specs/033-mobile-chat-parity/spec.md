# Feature Specification: One Chat on Every Screen

**Feature Branch**: `033-mobile-chat-parity`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Make iPhone and iPad chats look and work consistently with the MacOS."

## Why this feature exists

The Mac and the phone already read the same conversation from the same place. They show the same
entries, fold tool calls into the same runs and drop the same plumbing. They then draw it
separately, and the two copies have drifted apart. On the Mac a folded run of tool calls is one
sentence you click. On the phone it has a chevron and an "11 more" button. The Mac keeps up
with a reply as it streams in, and the phone only moves when a whole new entry arrives. On the Mac
a working agent shows a spinner at the foot of the chat, and on the phone nothing moves. A prompt
typed while the agent works shows as "Waiting its turn" on the Mac and disappears on the phone.
The Mac names the folder, the context used and the runtime just above the field. The phone puts
the meter in a bottom toolbar and says nothing about the other two.

The phone's prompt bar was also kept deliberately small: it talks to an agent and does nothing
else. That was the right first step, and it is now the gap people notice. From the phone you cannot
switch a running agent into plan mode, change its model, attach the screenshot you just took,
dictate, or see why an agent at its cost limit is not answering.

This feature treats the Mac chat as the reference. An open conversation on iPhone and iPad looks
and works like the Mac's, with the same controls, the same rows and the same behaviour. It differs
only where a touch screen or a narrow screen makes the Mac's way wrong, and each of those
differences is written down below.

Starting an agent from the phone is out of scope: 029 made it a screen of its own. This feature
covers the chat once the agent exists.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The conversation reads the same (Priority: P1)

Alex opens a conversation on the Mac, then on the phone. Each kind of line is drawn and worded the
same way on both, and behaves the same way when tapped. A run of tool calls is its latest line on
one row. Tapping it shows the whole run, and tapping one call in the run shows what it did: the
diff, the output, the files it touched and what the runtime sent. A working agent shows the same
small spinner at the foot of the chat. Prompts sent while it worked sit at the foot as "Waiting its
turn", lighter and dashed, each with a way to take it back.

**Why this priority**: The conversation is what people read on the phone, and it is where the
drift shows most. Every other story is about the controls around it.

**Independent Test**: Open the same conversation (with a multi-call tool run, a diff, a command,
a queued prompt, a failure line and an agent report) on the Mac and on the phone. Go through it
line by line and confirm each line has the same words, the same weight and the same tap/click
behaviour.

**Acceptance Scenarios**:

1. **Given** a folded run of several tool calls, **When** it is shown on the phone, **Then** it is
   one line (the latest call's), cut to a single line, with no chevron and no count, as on the Mac.
2. **Given** that folded run, **When** it is tapped, **Then** every call in the run is listed, and
   tapping one call shows its detail. A run of one call opens that call's detail straight away.
3. **Given** a call's detail, **When** it is shown on the phone, **Then** it includes what the
   runtime sent as input or output where there is one, in the same code style and height limit as
   the Mac.
4. **Given** a running or starting agent, **When** the foot of its conversation is shown, **Then**
   the same working spinner as the Mac is there, and it goes when the turn ends.
5. **Given** a prompt sent while the agent was working, **When** the conversation is shown on
   either device, **Then** it sits at the foot as "Waiting its turn", and removing it on one device
   removes it on the other.
6. **Given** any kind of transcript line (message, thought, plan, permission asked or answered,
   form asked or answered, summarising, state change, agent report, runtime note, served request,
   something the app does not recognise), **When** it is shown on the phone, **Then** its words are
   the Mac's words.
7. **Given** a file a tool call touched, **When** it is listed in the detail, **Then** it is named
   as on the Mac (`name:line` where a line is known), and tapping it opens what the agent did to
   that file (see Deliberate Differences).

---

### User Story 2 - Talking to a running agent works the same (Priority: P1)

Alex is away from the desk with the phone. An agent is heading the wrong way. They switch it to
plan mode, change its model, attach a screenshot, dictate what they want, and send. The agent is
still working, so the send button shows that the prompt will wait for the turn to end, and the
prompt appears as queued. Everything Alex set applies to that agent exactly as if it had been set
on the Mac, and the Mac shows the change.

**Why this priority**: This is the "work consistently" half, and a remote whose controls are a
subset of the Mac's is one you put down and walk back to the desk for.

**Independent Test**: On the phone, with a running agent, change each control the runtime
offers, attach a file and a picture, dictate a sentence and send. Confirm that the Mac shows each
change, the prompt queued, and the attachments with it.

**Acceptance Scenarios**:

1. **Given** an open conversation whose runtime offers controls (permission mode, model, effort,
   speed, or anything else it advertises), **When** the prompt area is shown on the phone,
   **Then** the same controls appear in the same order as on the Mac: permission ones first,
   then the rest.
2. **Given** a control changed on the phone, **When** the choice is made, **Then** the control
   shows the new value at once, and the running agent and the Mac window both have it.
3. **Given** a runtime that offers nothing, or controls that are still loading or failed to load,
   **When** the prompt area is shown, **Then** it says which of these it is, in the Mac's words,
   and never shows a silent gap.
4. **Given** the phone's field, **When** Alex attaches a photo, a picture from the clipboard or a
   file, **Then** it shows in a strip above the field, can be removed, and is refused with the
   same reason as on the Mac if the runtime cannot take it.
5. **Given** the phone's field, **When** Alex taps the microphone, **Then** what they say is added
   to what is already typed, and tapping again stops. The first use explains itself before the
   system asks for permission, as on the Mac.
6. **Given** a working agent, **When** Alex is about to send, **Then** the send button shows it
   will queue rather than send, with the Mac's icon and label, and the sent prompt appears as
   queued in the conversation.
7. **Given** a prompt that fails to reach the Mac, **When** the send fails, **Then** the words and
   attachments stay in the field, as today.

---

### User Story 3 - The same things around the field (Priority: P2)

Above the field, the phone shows what the Mac shows: where the agent is working (its folder, or its
worktree's name), how full its context is and what it has cost, and which runtime it is. When the
agent has hit its own cost limit, or the day's limit has been reached, the same banner as the Mac
says so above the field and offers the same ways out.

**Why this priority**: These answer "why is it not doing anything" and "what is it working in".
Without them the phone user has to go to the Mac to find out, which is what this feature is meant
to end.

**Independent Test**: Open an agent in a worktree that is at its cost limit. Confirm the phone
names the worktree, shows the meter and runtime above the field, and shows the limit banner.
Tap "Let this one go on" and confirm the agent can take prompts again on both devices.

**Acceptance Scenarios**:

1. **Given** an open conversation, **When** the prompt area is shown, **Then** the folder or
   worktree name, the context-and-cost meter and the runtime name sit in a row above the field, as
   on the Mac, and the meter no longer sits in a bottom toolbar.
2. **Given** an agent at its own cost limit, **When** its chat is open, **Then** the Mac's banner
   is shown with the amount spent, "Let this one go on", and a way to raise the limit.
3. **Given** the day's limit reached, **When** any chat is open, **Then** the Mac's day-limit
   banner is shown.
4. **Given** "Let this one go on" tapped, **When** it succeeds, **Then** only that agent's ceiling
   is raised, as on the Mac.

---

### User Story 4 - The chat moves the way the Mac's does (Priority: P2)

A reply streams in on the phone and the view keeps up with it word by word, not only when a new
entry lands. When Alex scrolls up to read, the view stays where they are, and the same "go to the
end" button appears, saying "Something new" if anything has arrived. When they send, the view goes
to the end. When a question card appears above the field, the last thing said is lifted clear of
it, not left under it. The conversation runs under the prompt area, the way it does on the Mac,
and scrolls clear of it.

**Why this priority**: Tapping the end button over and over to keep up with a live reply is the
most common complaint about reading on the phone, and the Mac solved it already.

**Independent Test**: With a long streaming reply open on the phone, confirm the view follows it
without a tap. Scroll up and confirm it stays put while text keeps arriving and the end button
says "Something new". Send a prompt and confirm the view goes to the end.

**Acceptance Scenarios**:

1. **Given** the reader at the end, **When** a reply grows by a few words, **Then** the view follows
   it smoothly without being tapped.
2. **Given** the reader scrolled away from the end, **When** anything arrives, **Then** the view
   does not move, and the end button says something new has arrived.
3. **Given** the reader following the end, **When** a permission or form card appears, **Then** the
   last thing said is scrolled clear of the card.
4. **Given** a prompt sent, **When** it goes, **Then** the view returns to the end and follows again.
5. **Given** the conversation, **When** it is scrolled, **Then** it runs under the prompt area and
   can be scrolled clear of it, and the scroll bar stops above it, as on the Mac.

---

### User Story 5 - Questions sit where the Mac puts them (Priority: P2)

When the agent asks for permission or sends a form, the card floats above the prompt area in the
chat's column, with the agent's own options, as on the Mac. The prompt area stays beneath it,
so a reader can see what they would be typing past. The phone keeps its taller treatment of the
same card: options stacked, and the command or diff shown in full. On a small screen a row of
three buttons becomes three truncated words.

**Why this priority**: Answering questions is what the phone is used for most. It already works;
this makes it sit and read the way it does on the Mac.

**Independent Test**: Trigger a permission request and then a form on an agent open on both.
Confirm that each card floats above the prompt area on the phone, as on the Mac, with the same
title, kind and options, and that answering on either device clears it on both.

**Acceptance Scenarios**:

1. **Given** a permission request, **When** the chat is open on the phone, **Then** the card floats
   above the prompt area with the Mac's title, kind and option wording, and the most permissive
   option is drawn the way the Mac draws it.
2. **Given** a form, **When** the chat is open on the phone, **Then** it floats above the prompt
   area in the same place.
3. **Given** a card answered on either device, **When** the answer lands, **Then** it is gone on
   both, and the transcript records the answer in the same words.

---

### User Story 6 - The same verbs, reached the same way (Priority: P3)

Stop is a visible button in the chat's top bar whenever the agent can be stopped, as on the Mac,
not an item in a menu. Archive sits beside it and returns to the project, as on the Mac. What
Alex had half typed in one conversation is still there when they come back to it, attachments and
all, and is never carried into another conversation. On an iPad with a keyboard, Return sends,
Option-Return adds a line, Tab takes the suggestion or the highlighted command, the arrow keys move
through the command list and Escape puts it away, as on the Mac.

**Why this priority**: Each of these is small. Together they decide whether the phone feels like
the same app.

**Independent Test**: On the phone, stop and then archive an agent from its chat. Type into two
conversations and move between them. On an iPad with a keyboard, work the command list and send
with the keyboard alone.

**Acceptance Scenarios**:

1. **Given** a running agent, **When** its chat is open, **Then** Stop is a button in the top bar,
   and tapping it stops the agent and stays on the chat.
2. **Given** an agent that is not archived, **When** Archive is tapped, **Then** it is archived and
   the view returns to the project. For an archived agent, "Bring back" is offered, as today.
3. **Given** words and an attachment typed into one conversation, **When** Alex opens another and
   comes back, **Then** the first conversation's draft is restored, and the second never showed
   it.
4. **Given** an iPad with a hardware keyboard, **When** the Mac's keys are used in the field,
   **Then** they do what they do on the Mac.
5. **Given** the phone's field, **When** Alex types `@` and part of a file name, **Then** the
   matching files from the agent's folder are offered, as on the Mac, and choosing one names it in
   the prompt.

### Edge Cases

- The Mac stops answering while the phone is open (stale): every control that would change
  something is disabled, the field says so, and nothing typed or attached is lost.
- A runtime whose options changed since the chat opened: the phone shows the new set, as the Mac
  does, and a choice made on a control that has gone is not sent.
- Two devices change the same control at almost the same time: the last change to reach the Mac
  wins, and both devices show that value.
- An attachment too large to send from the phone: it is refused before sending with a reason, and
  the rest of the prompt is not sent without it unless Alex removes it.
- Dictation refused by the system: the phone says so and, where a setting would fix it, offers to
  open it, as on the Mac.
- A terminal command's output that has not reached the phone: the call says it ran a command and
  shows what did reach the phone. It does not claim more.
- The narrowest iPhone in portrait: the control row scrolls sideways rather than wrapping or
  truncating the controls, as on a narrow Mac window.
- An archived agent: no prompt area, as today; the header row and meter still show.
- Something in the transcript this version does not recognise: the phone does what the Mac does,
  showing what the runtime sent rather than a generic sentence.

## Requirements *(mandatory)*

### Functional Requirements

**The conversation**

- **FR-001**: Every kind of transcript line MUST use the same words, the same text role and the same
  colour rule on iPhone, iPad and Mac. Colour is used only for failure and for a report that needs a
  person.
- **FR-002**: A folded run of tool calls MUST show as the latest call's line alone, cut to one
  line, with no chevron or count. Tapping it MUST unfold the run, and tapping one call in an
  unfolded run (or the only call in a run of one) MUST show that call's detail.
- **FR-003**: A call's detail MUST include what it produced (diff, content, terminal output where
  available), the files it touched as `name:line`, and the runtime's raw input or output, as on the
  Mac.
- **FR-004**: A working spinner MUST show at the foot of the conversation while the agent is running
  or starting, and go when it stops.
- **FR-005**: Prompts queued while the agent works MUST show at the foot of the conversation as on
  the Mac, and MUST be removable from the phone.

**The prompt area**

- **FR-006**: The phone's prompt area MUST offer every control the agent's runtime advertises,
  grouped and ordered as on the Mac, and a change MUST apply to the running agent and show on the
  Mac.
- **FR-007**: When there are no controls to show, the prompt area MUST say why, in the Mac's words,
  and offer "Try again" where the Mac does.
- **FR-008**: The phone MUST let a prompt carry attachments (photos, a pasted picture, files), shown
  in a removable strip, subject to the same runtime refusals as the Mac.
- **FR-009**: The phone MUST offer dictation from a button beside Send that adds to what is already
  typed, with a one-time explanation before the system's permission request.
- **FR-010**: The send button MUST show whether the prompt will go now or wait for the turn to end,
  as on the Mac.
- **FR-011**: A row above the field MUST show the folder or worktree name, the context-and-cost
  meter and the runtime name, as on the Mac. The meter MUST NOT also appear elsewhere in the
  chat.
- **FR-012**: The own-cost-limit and day-limit banners MUST show above the field with the Mac's
  words. "Let this one go on" MUST work from the phone.
- **FR-013**: `@` file mentions MUST offer files from the agent's folder, as on the Mac.
- **FR-014**: A draft (words and attachments) MUST be kept per conversation on the phone and
  restored on return, and MUST never appear in another conversation.
- **FR-015**: On an iPad with a hardware keyboard, Return, Option-Return, Tab, the arrow keys and
  Escape MUST do in the field what they do on the Mac.

**Behaviour and placement**

- **FR-016**: While following the end, the conversation MUST keep up with a reply as it streams in,
  not only when a new entry arrives. It MUST stop following only when the reader scrolls away,
  and resume when they return to the end or send.
- **FR-017**: The conversation MUST run under the prompt area and be scrollable clear of it. When a
  card appears above the prompt area, a reader who was following MUST be lifted clear of it.
- **FR-018**: Permission and form cards MUST float above the prompt area in the chat's column,
  with the prompt area still present beneath them, as on the Mac.
- **FR-019**: Stop MUST be a visible button in the chat's top bar whenever the agent can be stopped.
  Archive MUST sit beside it and return to the project.
- **FR-020**: On iPad, the conversation, the prompt area and the cards MUST share one column with
  the same edges and the same maximum reading width as the Mac's chat column.

**Keeping them together**

- **FR-021**: An automated check MUST fail when a transcript line or a prompt-area message is
  worded differently on the Mac and the phone, except for the differences listed below.
- **FR-022**: The differences between the Mac and the phone chat MUST be the ones listed under
  Deliberate Differences, and no others.

### Deliberate Differences

These stay, because the Mac's way would be wrong on a touch screen or a small one:

- **Opening a touched file**: the Mac opens it in the Mac's editor. The phone shows what the agent
  did to that file, in a sheet, because the phone cannot open the Mac's disk.
- **The suggested prompt**: the Mac shows it as placeholder text taken with Tab. The phone shows it
  as one chip, taken with a tap (031).
- **Permission cards**: the phone stacks the options and shows the command or change in full,
  because a row of buttons at large text sizes cannot be read.
- **Choosing a command**: the Mac highlights with the arrow keys. The phone chooses with a tap, and
  an iPad with a keyboard does both.
- **Top of the chat**: the phone keeps its stale banner and current-plan strip, which have no
  counterpart on the Mac. The Mac's window always has its daemon to hand.
- **Navigation**: the phone reaches a chat by a push with a back button, not a sidebar.
- **Hover help**: where the Mac explains a control on hover, the phone uses the accessibility
  label and hint.

### Key Entities

- **Agent controls**: The options a runtime advertises for an agent (permission mode, model,
  effort, speed and others), each with its choices and the value in force. Shared by both devices
  and changed from either.
- **Queued prompt**: Words and attachments sent while the agent was working, held until the turn
  ends, and removable until then.
- **Draft**: What has been typed and attached into one conversation's field but not sent, kept
  against that conversation on that device.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a conversation holding one of every kind of transcript line, a side-by-side read
  finds zero differences in wording or tap behaviour between the Mac and the phone, apart from the
  listed deliberate differences.
- **SC-002**: Every control the Mac's prompt area offers for an open agent can be reached from the
  phone in at most two taps.
- **SC-003**: A change made to an agent's control on the phone shows on the Mac within 2 seconds on
  a normal connection.
- **SC-004**: While following a streaming reply on the phone, the newest words are on screen with
  no taps from start to end of the reply.
- **SC-005**: Alex can stop a running agent from its phone chat in one tap.
- **SC-006**: The automated wording check fails when a transcript or prompt-area sentence is changed
  on one device only.
- **SC-007**: Nothing already possible from the phone chat (answering, reading back through history,
  opening a touched file, the suggestion chip, "Exchanged") is lost.

## Assumptions

- The Mac chat as it stands on main at `4bc5073` is the reference. Where the Mac changes later, the
  wording check is what keeps the phone in step.
- The phone reads files for `@` mentions and terminal output only through the Mac's daemon, never
  directly. Where the daemon does not yet send something (for example a command's live output), the
  plan adds it or the phone says what it has, not more.
- The phone's existing attachment handling from starting an agent (029), with its size limits, is
  what the chat uses. It is not a second set of rules.
- Dictation on the phone uses the device's own speech recognition, with the same append-to-what's-
  typed behaviour as the Mac.
- "Raise the limit" opens the phone's own cost-limit setting where the phone has one. Otherwise it
  says the limit is changed in Settings on the Mac. "Let this one go on" works from the phone
  either way.
- Starting an agent, the new-chat screen and the project page are out of scope (029, 020).
- The phone walk on a real device is Alex's. This Mac cannot tap a simulator.
