# Feature Specification: Chat Prompt Controls, Scroll-to-Bottom, and Remembered Mode

**Feature Branch**: `009-fix-chat-prompt-ux`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "We're doing some bug fixing. One bug is that the chat does not always seem to show the controls below the prompt input. Then it is not easy to scroll the chat to the bottom. Finally, we should remember the user's preferred "mode" option so they don't have to change it everytime."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The controls under the prompt are always there (Priority: P1)

Someone sitting in a chat wants to see, and change, what the agent is allowed to do and how it works — mode, model, effort, permissions — without leaving the conversation. Today that row of controls under the prompt is sometimes present and sometimes simply absent, with nothing in its place, so the person cannot tell whether the chat has no controls, whether the app is still fetching them, or whether something went wrong. They end up starting a new chat to get the controls back.

**Why this priority**: It is the loss of a control surface, not a cosmetic glitch. When the row is missing the person cannot change the agent's mode at all, which also blocks the value of Story 3. Everything else in this feature is an improvement on top of a surface that must first be reliably present.

**Independent Test**: Open chats in each of the states where the row is known to vanish — a brand-new chat before a folder or runtime is chosen, a new chat while its options are being fetched, an existing chat opened fresh from the sidebar, a chat whose runtime advertised nothing, and a chat where fetching the options failed — and confirm that in every case the area under the prompt shows either working controls or a plain statement of why there are none.

**Acceptance Scenarios**:

1. **Given** an existing conversation selected from the sidebar, **When** the chat opens, **Then** the same controls that were available when the conversation was started are shown under the prompt, set to the values currently in force.
2. **Given** a new chat with a folder and a runtime chosen, **When** the app is still fetching what that runtime offers, **Then** the area under the prompt tells the person that it is asking, and the controls replace that message when they arrive.
3. **Given** a new chat with no folder or no runtime chosen yet, **When** the person looks under the prompt, **Then** they are told what they must choose before the controls can appear, rather than seeing an empty gap.
4. **Given** a runtime that genuinely advertises no adjustable options, **When** the chat is open, **Then** the person is told plainly that this runtime offers nothing to adjust.
5. **Given** fetching the runtime's options failed, **When** the chat is open, **Then** the person is told it failed and can ask for it again without restarting the chat or the app.
6. **Given** a chat where the controls are shown, **When** the window is made narrow enough that the controls no longer fit side by side, **Then** every control remains reachable rather than being pushed off the edge.

---

### User Story 2 - Getting back to the end of the conversation (Priority: P2)

Someone reads back through a long conversation, then wants to return to the live end of it — where the agent is working now and where their next prompt will land. Today the only way back is to scroll, which in a long transcript is a long way, and while they are scrolled up they cannot tell that the agent has said anything new.

**Why this priority**: The conversation is still usable without it — scrolling works — but in a long transcript the cost is high and it is felt on every single read-back. It sits below Story 1 because a missing control is a lost capability, whereas this is a slow path to something still reachable.

**Independent Test**: Open a conversation long enough to scroll, scroll well up into it, and confirm both that a way back to the end appears and that taking it lands at the last line, below anything newly arrived.

**Acceptance Scenarios**:

1. **Given** a conversation scrolled away from its end, **When** the person looks at the chat, **Then** a clearly visible way to return to the end is offered.
2. **Given** that affordance is showing, **When** the person takes it, **Then** the view moves to the last line of the conversation and the affordance goes away.
3. **Given** the conversation is already at its end, **When** the person looks at the chat, **Then** no return affordance is shown, because it would do nothing.
4. **Given** the person is scrolled up reading, **When** the agent adds new lines, **Then** the view stays where they are reading and the return affordance indicates that there is something new below.
5. **Given** the person is scrolled up, **When** they send a prompt, **Then** the view returns to the end so they can see their prompt and the reply that follows it.
6. **Given** a conversation of any length, **When** the person uses the keyboard rather than the pointer, **Then** there is a keyboard route to the end of the conversation.

---

### User Story 3 - The mode you chose last time is the mode you get (Priority: P3)

Someone who nearly always works in one particular mode has to change it away from the runtime's default every time they start a chat. The choice does not stick, so the same adjustment is made over and over, and when it is forgotten the agent starts with permissions the person did not intend.

**Why this priority**: It is repeated friction rather than a blockage — the mode can always be set by hand. It depends on Story 1, since a control that is not shown cannot carry a remembered value, so it comes after it.

**Independent Test**: Change the mode on a new chat, start it, then begin another new chat with the same runtime and confirm the control opens on the mode chosen last time rather than the runtime's default; quit and reopen the app and confirm it is still remembered.

**Acceptance Scenarios**:

1. **Given** a person who chose a non-default mode when starting a chat, **When** they begin another new chat with the same runtime, **Then** the mode control is already set to the mode they chose last time.
2. **Given** a remembered mode, **When** the app is quit and reopened, **Then** the mode is still remembered.
3. **Given** a remembered mode, **When** the person changes it on a new chat, **Then** the new choice replaces the remembered one for chats that follow.
4. **Given** a remembered mode, **When** the person starts a chat with a different runtime that does not offer that mode, **Then** that runtime's own default is used and no error is shown.
5. **Given** a remembered mode that a runtime has stopped offering, **When** a new chat starts with that runtime, **Then** the runtime's current default is used and the stale value is discarded.
6. **Given** a conversation already under way, **When** the person changes its mode, **Then** only that conversation changes, and the remembered preference for new chats is updated to match.

---

### Edge Cases

- What happens when the runtime is slow or unreachable while its options are being fetched — how long before the person is told, and can they retry?
- What happens when the person switches runtime or folder on a new chat while the previous fetch is still running, so a stale set of controls could arrive after the new one?
- What happens when the transcript is shorter than the pane, so there is nothing to scroll — the return-to-end affordance must not appear.
- What happens when new lines arrive while the person is scrolled up and then they scroll to the end by hand — the "something new" indication must clear.
- What happens when earlier history is loaded in at the top of a long transcript — the reader's place must be kept, and the return-to-end affordance must remain accurate.
- What happens when a permission request or a form is showing above the prompt, making the floating prompt area taller — the controls and the end of the conversation must both remain reachable.
- What happens when the mode was remembered under a name a newer version of the runtime no longer uses.
- What happens on the very first run, with nothing remembered — the runtime's own default must be used.

## Requirements *(mandatory)*

### Functional Requirements

#### The controls under the prompt

- **FR-001**: The area under the prompt MUST always show one of four things: the working controls, a statement that they are being fetched, a statement of what the person must choose first, or a statement that the runtime offers nothing to adjust. It MUST never be silently empty.
- **FR-002**: For a conversation that has already been started, the controls MUST reflect the options that conversation's runtime advertises and MUST show the value currently in force for each.
- **FR-003**: Where a conversation was started but its advertised options are not known to the app, the app MUST obtain them rather than showing nothing.
- **FR-004**: When fetching a runtime's options fails, the person MUST be told, and MUST be able to try again from the chat without restarting the chat or the app.
- **FR-005**: Changing folder or runtime on a new chat MUST cause the controls to be fetched again, and a result arriving for a folder or runtime the person has since moved away from MUST NOT be displayed.
- **FR-006**: All controls MUST remain reachable at every window width the app supports, with no control clipped or pushed out of view.

#### Getting to the end of the conversation

- **FR-007**: When the conversation is scrolled away from its end, the app MUST offer a visible way to return to the end.
- **FR-008**: Taking that route MUST bring the last line of the conversation into view, clear of the prompt area and anything floating above it.
- **FR-009**: The route MUST be hidden when the conversation is already at its end and when the conversation is too short to scroll.
- **FR-010**: While the person is scrolled away from the end, the conversation MUST NOT jump to the end on its own when new lines arrive.
- **FR-011**: When new lines arrive while the person is scrolled away from the end, the return route MUST indicate that there is something new to see.
- **FR-012**: Sending a prompt MUST return the view to the end of the conversation.
- **FR-013**: There MUST be a keyboard route to the end of the conversation.
- **FR-014**: Loading earlier history MUST leave the reader looking at the line they were reading, and MUST NOT be mistaken for new content arriving.

#### Remembering the mode

- **FR-015**: The app MUST remember the mode the person last chose, per runtime, and MUST apply it as the starting value of the mode control on new chats with that runtime.
- **FR-016**: The remembered mode MUST survive quitting and reopening the app.
- **FR-017**: Where the remembered mode is not among the modes a runtime currently offers, the app MUST fall back to that runtime's own default without showing an error, and MUST discard the stale value.
- **FR-018**: Where nothing has been remembered for a runtime, that runtime's own default MUST be used.
- **FR-019**: Changing the mode on a conversation already under way MUST affect only that conversation, and MUST update what is remembered for new chats.
- **FR-020**: Only the mode is remembered by this feature; other options continue to start from whatever the runtime advertises as current.

### Key Entities

- **Mode preference**: The mode the person last chose, held per runtime, outliving any one chat and any one run of the app. Holds the runtime it belongs to and the chosen mode's identifier.
- **Prompt controls state**: What the area under the prompt is currently showing — fetching, nothing chosen yet, nothing offered, failed, or a set of controls — so that it always has something to say.
- **Reading position**: Whether the conversation is at its end or scrolled away from it, and whether anything has arrived since the person scrolled away.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In every one of the chat states listed in User Story 1's independent test, the area under the prompt shows working controls or a plain explanation — never an unexplained gap. 100% of those states pass.
- **SC-002**: A person can change the agent's mode from within any open conversation without starting a new chat, in every state where the runtime offers modes.
- **SC-003**: Returning to the end of a conversation of any length takes one action, instead of repeated scrolling.
- **SC-004**: A person whose preferred mode differs from the runtime's default makes zero mode changes across their second and subsequent new chats with that runtime.
- **SC-005**: No conversation moves the reader's position on its own while they are scrolled away from the end, across a sustained agent turn.
- **SC-006**: Every control under the prompt is reachable at the app's minimum supported window width.

## Assumptions

- "Controls below the prompt input" means the row of option controls — mode, model, effort, permissions, and reach — that sits beneath the text field, not the send, attach, and dictate buttons inside the field itself.
- The mode preference is remembered per runtime. Modes are runtime-specific, so a mode chosen for one runtime is usually meaningless to another; a single global preference would fall back to the default most of the time.
- The mode preference is not scoped per folder or per project. This is the most likely thing to want differently, and is the first candidate for `/speckit-clarify`.
- Remembering applies to new chats. A conversation already under way keeps whatever mode it is running with until the person changes it there.
- The preference lives on the machine the app runs on, alongside the other window and selection preferences, rather than being held centrally or synced between machines.
- Existing behaviour that is already right is kept: a conversation opens at its end, follows itself while the reader is at the end, and keeps the reader's place when earlier history is loaded in.
- No new option is invented. "Mode" is whichever option the runtime already advertises under that heading; runtimes that advertise none are unaffected.
- The three fixes are independent and can ship separately, in priority order.
