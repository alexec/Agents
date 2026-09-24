# Feature Specification: Stop Is a Button, Like Archive

**Feature Branch**: `026-stop-button`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "a stop button (like archive) to stop sessions."

## Why this feature exists

Stopping an agent is already a thing the app can do, and does well. The daemon stops a turn in
flight, answers any question the agent was waiting on as cancelled, lets the runtime go, withdraws
a chat that was about to be picked back up, and writes the ending down as *Stopped by you*. The phone
offers it in the chat's menu.

On the Mac, though, the only way to reach it is to right-click an agent's card. Nothing on the chat
page itself says it can be stopped. Archive is right there in the toolbar — one click, and the chat
is put away — so the page teaches that the way to make an agent stop is to archive it, which also
throws it out of sight. The person reading a chat that has gone the wrong way wants the opposite:
to stop it *and keep reading*, then say what next.

There is also a small hole in the one route that exists. A chat that the daemon is bringing back
after a restart holds no runtime yet, so the card's menu does not offer Stop — though stopping it is
exactly what the daemon knows how to do, and exactly what someone who did not want it resumed would
reach for.

**This feature does not change what stopping does.** It changes where it can be reached from.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Stop the chat you are reading (Priority: P1)

Someone is reading an agent's chat while it works and sees it heading somewhere they did not mean.
Beside Archive in the chat's toolbar there is a Stop button. They click it. The agent stops, the
chat stays open where they were reading, the ending is shown as stopped by them, and the prompt bar
invites them to say what next.

**Why this priority**: It is the whole of the request. Everything else here is the same control
reaching the cases the first one misses.

**Independent Test**: Start an agent on a task that takes a minute, open its chat, click Stop in the
toolbar. Confirm the turn ends within a few seconds, the chat is still the one on screen, the
transcript ends with the stop, and a new prompt starts the agent again.

**Acceptance Scenarios**:

1. **Given** an agent that is starting, working, or waiting on the person, **When** its chat is open, **Then** a Stop button is shown in the toolbar beside Archive.
2. **Given** that button, **When** the person clicks it, **Then** the agent stops exactly as it does when stopped from the card's menu today, and is recorded as stopped by them.
3. **Given** the person has just clicked Stop, **When** the agent has stopped, **Then** the same chat is still on screen, scrolled where it was — unlike Archive, Stop does not leave the page.
4. **Given** an agent that has stopped, **When** its chat is open, **Then** the Stop button is gone, and Archive is still there.
5. **Given** an agent that is finished, stopped, or archived, **When** its chat is opened, **Then** no Stop button is shown.
6. **Given** a stopped agent, **When** the person sends it a new prompt, **Then** it starts again as it does today.

---

### User Story 2 - Stop a chat that is coming back (Priority: P2)

The Mac restarted with an agent working. The daemon is bringing that chat back by itself, and the
person does not want it to carry on. Its card says it is coming back. They can stop it — from the
chat's toolbar and from the card's menu — and it does not come back.

**Why this priority**: It is the one case where the existing Stop is missing when it is most
wanted. It depends on Story 1 only for the toolbar half.

**Independent Test**: With an agent working, stop the daemon outright and start it again. While the
card says the chat is coming back, click Stop. Confirm it is never resumed and its transcript says
the person stopped it.

**Acceptance Scenarios**:

1. **Given** a chat the daemon is bringing back after a restart, **When** its chat is open, **Then** the Stop button is shown.
2. **Given** such a chat, **When** its card's menu is opened, **Then** Stop is offered.
3. **Given** the person stops such a chat, **When** the daemon would otherwise have resumed it, **Then** it is not resumed, it stops being shown as coming back, and its transcript says the person stopped it before it was picked back up. *(Amended at implementation: it keeps the ending it already had — stopped with the daemon — because the existing stop does not rewrite an ending an agent already has, and this feature does not change what stopping does.)*
4. **Given** such a chat on the phone, **When** its chat menu is opened, **Then** Stop is offered there too.

---

### User Story 3 - Stop from the keyboard (Priority: P3)

Someone who lives on the keyboard presses ⌘. while reading a working chat, the way they would stop
anything else on a Mac, and it stops.

**Why this priority**: A convenience on top of the button, and the Mac's own word for stop.

**Independent Test**: With a working chat open and the prompt bar focused, press ⌘. and confirm the
agent stops. With a finished chat open, press it and confirm nothing happens.

**Acceptance Scenarios**:

1. **Given** a chat the Stop button is shown for, **When** the person presses ⌘., **Then** it does exactly what clicking the button does.
2. **Given** a chat the Stop button is not shown for, **When** the person presses ⌘., **Then** nothing happens.

---

### Edge Cases

- **The turn ends on its own just as Stop is clicked.** The agent keeps the ending it actually had; the click does nothing visible and shows no error.
- **Stop is clicked twice.** The second click does nothing; the agent is stopped once and the transcript says so once.
- **The agent was waiting on a permission question or a form.** The question card goes away as it does when stopped from the card's menu today, answered as cancelled.
- **The agent has prompts queued behind the current turn.** They are treated as the existing stop treats them; this feature does not change that.
- **The daemon refuses or cannot be reached.** The failure reaches the person the way any other failed action on the chat does today, and the button is still there to try again.
- **The phone has lost touch with the Mac.** Stop is shown but disabled, as the phone's other actions already are.
- **The chat is a workflow's agent.** Stopping it stops that agent only; the workflow and its other runs are untouched, and the triggers that watch for an agent stopping fire as they do today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The chat page on the Mac MUST show a Stop control in its toolbar, beside Archive, whenever the agent it shows is starting, working, waiting on the person, or being brought back after a restart.
- **FR-002**: The Stop control MUST NOT be shown for an agent that is finished, stopped, or archived — except a stopped one the daemon is bringing back, which FR-001 covers.
- **FR-003**: Activating Stop MUST do exactly what the existing stop does — the same ending, the same transcript entry, the same triggers, the same handling of pending questions — with no separate path. Which states offer Stop MUST be decided in one place that the Mac and the phone both read.
- **FR-004**: Activating Stop MUST leave the person on the same chat, at the same place in it.
- **FR-005**: Stop MUST NOT ask for confirmation, since a stopped agent can be started again with a prompt.
- **FR-006**: The Stop control MUST use the same word and symbol as the phone's Stop, and carry a tooltip and an accessibility label saying what it does.
- **FR-007**: The card's menu on the Mac, and the chat's menu on the phone, MUST offer Stop for a chat being brought back after a restart, as well as for one holding a runtime.
- **FR-008**: A chat stopped while it was being brought back MUST NOT be resumed afterwards.
- **FR-009**: ⌘. MUST activate Stop on the chat page when, and only when, the Stop control is shown.
- **FR-010**: Activating Stop on an agent that has already ended MUST change nothing and show no error.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From an open, working chat, a person can stop the agent in one click or one keystroke, without leaving the page.
- **SC-002**: The agent's turn has visibly ended within 5 seconds of Stop being activated, for every runtime the app supports.
- **SC-003**: In every state where the daemon would accept a stop, the Mac's chat page, the Mac's card menu and the phone's chat menu all offer it; in every other state, none of them do.
- **SC-004**: A chat stopped while coming back after a restart is never resumed — zero resumes across repeated trials.
- **SC-005**: No one needs to archive a chat in order to stop it.

## Assumptions

- The daemon's existing stop is correct and complete; this feature only adds ways to reach it.
- Archive keeps its current behaviour of stopping the agent first and leaving the page; nothing about it changes.
- The Mac is the primary target; the phone already has a Stop in its chat menu and only needs the coming-back case (FR-007).
- No Stop button is added to the agent cards themselves; the card keeps Stop in its menu, and the swipe stays Archive.
- ⌘. is not already bound anywhere in the app.
- Whether a chat is being brought back is already known to the app, as the card already shows it.
