# Feature Specification: Starting agents on iPhone

**Feature Branch**: `029-start-agents-on-iphone`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Starting agents on iPhone."

**Clarified 2026-09-24**: The choices offered first are remembered once, on the Mac, and shared by
the Mac and every remote. Extra folders and MCP servers stay on the Mac.

## Why this feature exists

The phone can already answer an agent, read what it did and tell it what to do next. It cannot
start one. So a thought on the train, like "the flaky test in the daemon, have something look at
it", has to wait until the user is back at the Mac. By then it is either forgotten or it has cost
the half hour the agent could have spent on it while the user was travelling.

Starting an agent is the one thing the remote still leaves at the desk. 005 promised it. 013
planned it for the iPad as T072 but never built it. This feature builds it on the phone first,
where the screen is smallest and the need comes up most often. The same screen serves the iPad.

The work still happens on the Mac. The phone only says what to start, where and with what prompt.
The agent runs in the project's folder on the Mac, on the Mac's runtimes, and appears on the Mac
as though it had been started there.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an agent in a project with a prompt (Priority: P1)

The user is away from the Mac. They open the remote on their phone, go into a project and tap to
start an agent. They type what they want done and send it. A moment later the new agent is in the
project's Working group, and its conversation opens with their prompt at the top and the agent's
reply arriving under it.

**Why this priority**: This is the feature. A new agent with a prompt, in the right project, on the
runtime the user usually uses, covers most of what somebody wants to do from a phone. Everything
else here is about choosing something other than the usual.

**Independent Test**: With the phone on cellular data and the Mac on another network, go into a
project on the phone, start an agent with a one-line prompt and nothing else chosen, and confirm
the agent runs on the Mac in that project's folder, shows on both the phone and the Mac, and
replies.

**Acceptance Scenarios**:

1. **Given** a project is open on the phone, **When** the user looks at the project, **Then** a
   way to start an agent is visible without scrolling, and it is named as it is on the Mac.
2. **Given** the start screen is open, **When** it draws, **Then** the prompt field has the
   keyboard, and the runtime, model and mode already chosen are shown, so the user can send
   without choosing anything.
3. **Given** the user has typed a prompt, **When** they send it, **Then** the agent starts in the
   project's folder on the Mac, and the phone goes to its conversation showing the prompt as sent.
4. **Given** the agent has started from the phone, **When** the user looks at the Mac's window,
   **Then** the agent is there in the same project and group, with the same prompt, and nothing
   about it differs from one started at the Mac.
5. **Given** the start screen is open with a prompt typed, **When** the user leaves it without
   sending, **Then** what they typed is still there when they come back to start an agent in the
   same project.
6. **Given** the prompt field is empty, **When** the user looks at the send control, **Then** it
   cannot be used.

---

### User Story 2 - Choose how the agent starts (Priority: P2)

The user wants this one on a different runtime, or a stronger model, or in plan mode. On the start
screen they change the runtime. The choices under it change to that runtime's own. They pick the
model and mode they want and send.

**Why this priority**: The usual choices are right most of the time, and P1 is worth having without
this. But a user who cannot choose the runtime or model from the phone has to go to the Mac for the
cases that matter most: the expensive task and the risky one.

**Independent Test**: On the phone, pick a runtime other than the one offered, change its model and
mode, start the agent, and confirm on the Mac that it started on that runtime with those choices.
Then open the Mac's start controls and confirm they offer the same choices first.

**Acceptance Scenarios**:

1. **Given** the start screen, **When** the user opens the runtime choice, **Then** it lists the
   runtimes the Mac has, in the Mac's order and with the Mac's names, and marks any the Mac cannot
   start right now with the Mac's reason.
2. **Given** a runtime is chosen, **When** its choices draw, **Then** they are the choices that
   runtime offers on the Mac (model, mode, effort and anything else it advertises) and no others.
3. **Given** the runtime is changed, **When** the new one has different choices, **Then** the
   choices change to the new runtime's, and a choice that does not exist there is not carried over.
4. **Given** the runtime's choices are still being fetched, **When** the user looks, **Then** they
   see that the choices are coming, and can still send with the runtime's defaults.
5. **Given** the user starts an agent with particular choices on the phone, **When** they next start
   one on the phone or at the Mac, **Then** the same choices are offered first.
6. **Given** the user starts an agent with particular choices at the Mac, **When** they next start
   one on the phone, **Then** the same choices are offered first.
7. **Given** a runtime's choices cannot be fetched, **When** the start screen draws, **Then** it
   says why in one sentence and still lets the user start with the runtime's defaults.

---

### User Story 3 - Attach a picture or file to the first prompt (Priority: P3)

The user has a screenshot of a broken screen on their phone. They start an agent and attach the
screenshot to the prompt, so the agent can see what they mean.

**Why this priority**: The phone is where the screenshots are, and "look at this" is a natural first
prompt. But a prompt in words is enough to start most work, so this comes after choosing the
runtime.

**Independent Test**: Start an agent from the phone with a photo from the library attached, and
confirm the agent on the Mac received the picture with the prompt.

**Acceptance Scenarios**:

1. **Given** the start screen, **When** the user attaches a picture from the photo library or a
   file from Files, **Then** it is shown with the prompt before sending and can be removed.
2. **Given** the chosen runtime cannot take pictures, **When** the user tries to send with one
   attached, **Then** sending is refused before anything is sent, with the Mac's sentence saying
   why, and nothing is lost.
3. **Given** a picture is attached, **When** the agent starts, **Then** it arrives with the prompt
   as one message, as it would from the Mac.

---

### Edge Cases

- **The Mac is not answering.** The start screen can still be opened and typed in, but sending is
  refused when it is tried, saying the Mac is not answering and since when. The prompt stays in
  the field.
- **The connection drops while sending.** The agent is started once or not at all. When the phone
  reconnects it shows which: the new agent, or the prompt still in the field with a sentence saying
  it was not sent.
- **Send is tapped twice.** One agent starts.
- **The day's spending limit has been reached.** Starting is refused with the Mac's sentence about
  the limit, and the prompt stays in the field.
- **The project's folder is gone on the Mac.** Starting is refused, as on the Mac, with a sentence
  saying why. The project's agents stay readable.
- **The project is archived on the Mac while the start screen is open.** Sending is refused with a
  sentence saying the project was archived, and the prompt is kept.
- **The chosen runtime is removed or stops working on the Mac.** The phone shows it as unavailable
  with the Mac's reason, and asks for another before sending.
- **No runtimes are set up on the Mac.** The start screen says so and that runtimes are set up at
  the Mac, instead of offering an empty list.
- **A remembered choice the runtime no longer offers.** It is dropped silently and the runtime's
  current value is offered, as on the Mac.
- **The Mac's remembered choices from before this feature.** They are carried over the first time,
  so nobody's usual mode is lost when the memory moves.
- **A long prompt.** The field grows up to a limit and then scrolls. Nothing is cut off.
- **Dictation.** The system keyboard's dictation works in the prompt field.
- **The iPad.** The same start screen is used there, laid out for the larger screen. This closes
  013's T072.

## Requirements *(mandatory)*

### Functional Requirements

#### Starting

- **FR-001**: Users MUST be able to start an agent in an existing project from the iPhone remote.
- **FR-002**: An agent started from the phone MUST run on the Mac, in the project's folder, and MUST
  be indistinguishable on the Mac from one started there.
- **FR-003**: Starting MUST require a prompt. An empty prompt MUST NOT start an agent.
- **FR-004**: After a successful start, the phone MUST show the new agent's conversation.
- **FR-005**: The new agent MUST appear on the Mac and on every other connected remote within the
  time feature 005 promises for any change.
- **FR-006**: A start MUST take effect at most once, however many times send is tapped and however
  the connection behaves.

#### Choosing

- **FR-007**: Users MUST be able to choose the runtime from those the Mac has, shown with the Mac's
  names and in the Mac's order.
- **FR-008**: Users MUST be able to set every choice the chosen runtime advertises on the Mac
  (such as model, mode and effort), and only those.
- **FR-009**: The start screen MUST offer first the runtime and choices last used to start an agent,
  on any device, so an agent can be started without choosing anything.
- **FR-010**: The last-used runtime and choices MUST be remembered once, on the Mac, and shared by
  the Mac and every remote. A start on any of them MUST update what all of them offer first.
- **FR-011**: Choices the Mac already remembers when this feature arrives MUST be kept.
- **FR-012**: A runtime the Mac cannot start right now MUST be shown as unavailable with the Mac's
  reason, and MUST NOT be startable.

#### Attaching

- **FR-013**: Users MUST be able to attach pictures from the photo library and files from Files to
  the first prompt, see them before sending, and remove them.
- **FR-014**: An attachment the chosen runtime cannot take MUST be refused before sending, with the
  same reason the Mac gives.

#### Refusing and keeping

- **FR-015**: A start that cannot be delivered, or that the Mac refuses (not answering, spending
  limit, missing folder, archived project, unavailable runtime), MUST be refused when it is tried,
  with one sentence saying why, in the Mac's words where the Mac has them.
- **FR-016**: A prompt and its attachments MUST NOT be lost because of a refusal, leaving the start
  screen, or the app going to the background. They MUST be there when the user comes back to start
  an agent in the same project.
- **FR-017**: A prompt kept on the phone MUST be cleared once the agent it was typed for has
  started.

#### Fit

- **FR-018**: The start screen MUST fit an iPhone in portrait, with the prompt field and send
  reachable while the keyboard is up, and every choice reachable without the keyboard covering it.
- **FR-019**: The start screen MUST use the Mac's words for runtimes, choices, groups and actions.
- **FR-020**: Every control on the start screen MUST have an accessibility label, and the screen
  MUST stay usable at the largest Dynamic Type setting.
- **FR-021**: The same start screen MUST serve the iPad remote.

### Key Entities

- **Project**: a project that already exists on the Mac, with a folder and a list of agents. The
  phone starts agents in one. It does not create projects.
- **Runtime**: an agent program the Mac has set up, with a name, whether it can be started right now
  and why not, and the choices it advertises.
- **Remembered choices**: the runtime and choice values last used to start an agent. Held once, on
  the Mac, and read by every device.
- **Start draft**: the prompt and attachments on a start screen that has not been sent, kept on the
  phone per project until sent.
- **Agent**: the agent that results, the same thing the Mac shows.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From the remote's project page, a user can start an agent with the usual choices and a
  one-line prompt in under 15 seconds, with no more than three taps besides typing.
- **SC-002**: The new agent's conversation is on the phone within 2 seconds of sending on a
  reasonable mobile connection, and the agent is on the Mac within the same time.
- **SC-003**: Across 20 starts that include dropped connections and double taps, every start produces
  exactly one agent or none, and none loses a typed prompt.
- **SC-004**: Checked side by side, every runtime and choice the Mac's start controls offer is
  offered on the phone, and both offer the same ones first after a start on either.
- **SC-005**: Every refusal in the edge cases above appears on the phone as one sentence, with the
  prompt still in the field.
- **SC-006**: The start screen is walked on a real iPhone, with every control reached with the
  keyboard both up and down, before the feature ships.

## Assumptions

- **Existing projects only.** Adding a project, including from a git URL (027), stays at the Mac.
- **Folders and servers stay on the Mac.** Extra folders, MCP servers and free-text extra arguments
  are not offered on the phone. An agent started from the phone gets none, as an agent started at
  the Mac does when none are added.
- **One agent per start.** Starting several at once, or from a template or workflow, is out of
  scope.
- **Remembered choices are app-wide, as they are on the Mac today,** not per project. Moving them to
  the Mac's background service is what lets the phone share them.
- **Drafts stay on the phone.** An unsent prompt is not shared with the Mac or the iPad.
- **Pairing, notifications and the phone's other screens are as 005 and 013 left them.** Layout
  defects on the phone's other screens are not fixed here unless they are in the way of starting.
- **Stopping, archiving and unarchiving from the remote (013's T073) are not part of this feature.**
