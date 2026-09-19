# Feature Specification: Prompt Controls, Project Navigation, Scroll-to-Bottom, and Remembered Mode

**Feature Branch**: `009-fix-chat-prompt-ux`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "We're doing some bug fixing. One bug is that the chat does not always seem to show the controls below the prompt input. Then it is not easy to scroll the chat to the bottom. Finally, we should remember the user's preferred "mode" option so they don't have to change it everytime."

**Added 2026-09-19**: "Clicking on the project in the sidebar should always take you to the project page. If you are on the agent page it does not do this."

**Added 2026-09-19**: "Answering a question should only require one click. Change the radio button into a button."

**Added 2026-09-19**: "When the agent shows a file, tell the user that the agent needs user attention." (Two copy changes requested in the same breath — "running" to "working", "finished" to "complete" — were applied directly and are not part of this spec.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The controls under the prompt are always there (Priority: P1)

Someone sitting in a chat wants to see, and change, what the agent is allowed to do and how it works — mode, model, effort, permissions — without leaving the conversation. Today that row of controls under the prompt is sometimes present and sometimes simply absent, with nothing in its place, so the person cannot tell whether the chat has no controls, whether the app is still fetching them, or whether something went wrong. They end up starting a new chat to get the controls back.

**Why this priority**: It is the loss of a control surface, not a cosmetic glitch. When the row is missing the person cannot change the agent's mode at all, which also blocks the value of Story 5. The other fixes are improvements on top of a surface that must first be reliably present.

**Independent Test**: Open chats in each of the states where the row is known to vanish — a brand-new chat before a folder or runtime is chosen, a new chat while its options are being fetched, an existing chat opened fresh from the sidebar, a chat whose runtime advertised nothing, and a chat where fetching the options failed — and confirm that in every case the area under the prompt shows either working controls or a plain statement of why there are none.

**Acceptance Scenarios**:

1. **Given** an existing conversation selected from the sidebar, **When** the chat opens, **Then** the same controls that were available when the conversation was started are shown under the prompt, set to the values currently in force.
2. **Given** a new chat with a folder and a runtime chosen, **When** the app is still fetching what that runtime offers, **Then** the area under the prompt tells the person that it is asking, and the controls replace that message when they arrive.
3. **Given** a new chat with no folder or no runtime chosen yet, **When** the person looks under the prompt, **Then** they are told what they must choose before the controls can appear, rather than seeing an empty gap.
4. **Given** a runtime that genuinely advertises no adjustable options, **When** the chat is open, **Then** the person is told plainly that this runtime offers nothing to adjust.
5. **Given** fetching the runtime's options failed, **When** the chat is open, **Then** the person is told it failed and can ask for it again without restarting the chat or the app.
6. **Given** a chat where the controls are shown, **When** the window is made narrow enough that the controls no longer fit side by side, **Then** every control remains reachable rather than being pushed off the edge.

---

### User Story 2 - Clicking a project takes you to the project (Priority: P2)

Someone reading a conversation wants to get back out to the project it belongs to — to see the
other agents working there, or to start another one. The project is right there in the sidebar
with its name highlighted, so they click it. Nothing happens. They click it again. Still nothing.
The only way out is the back button in the toolbar, which is not where they were looking.

**Why this priority**: A control that silently does nothing is worse than one that is absent,
because the person does not learn from it — they click again, and then they doubt the app rather
than the control. It is also hit on every single exit from a conversation. It sits below Story 1
only because there is a working way home, so this is a broken second route rather than a lost
capability.

**Independent Test**: Open a conversation, then click that conversation's own project in the
sidebar — the row that is already highlighted. You should land on the project page.

**Acceptance Scenarios**:

1. **Given** a conversation is open, **When** the person clicks that conversation's own project in the sidebar, **Then** the project page is shown.
2. **Given** a conversation is open, **When** the person clicks a different project in the sidebar, **Then** that project's page is shown and the conversation is left. (This works today and must keep working.)
3. **Given** the project page is already showing, **When** the person clicks that same project in the sidebar, **Then** nothing changes and nothing flickers.
4. **Given** a conversation is open, **When** the person moves through the project list with the keyboard, **Then** landing on a project shows its page, including the one they started from.
5. **Given** a conversation is open, **When** the person uses the back control instead, **Then** it works exactly as it does today.
6. **Given** the person clicks a project, **When** the page appears, **Then** the prompt on it is pointed at that project's folder, ready to start an agent there.

---

### User Story 3 - The controls answer the moment you click them (Priority: P3)

Someone changes the mode on a conversation that is already under way. The menu closes and the
control still reads what it read before. Nothing says the click landed. They click it again,
choose the same thing again, and a second later both changes arrive at once. On a busy runtime
the wait is long enough to be sure it is broken rather than slow.

**Why this priority**: It is the same surface as Story 1 and the same feeling — a control you
cannot trust — but the control is present and does eventually work, so it sits below the one
that vanishes and below the one that does nothing at all. It is felt on every single option
change, and the fix is small.

**Independent Test**: Open a conversation with a live agent, change its mode, and watch the
control. It should read the new value before the menu has finished closing.

**Acceptance Scenarios**:

1. **Given** a conversation with a live agent, **When** the person chooses a different value in an option control, **Then** the control reads the new value immediately, without waiting for the runtime.
2. **Given** the runtime is slow to answer, **When** the person has chosen a value, **Then** the control keeps showing their choice for the whole wait rather than reverting and re-arriving.
3. **Given** the runtime refuses the change or answers with something else, **When** its answer arrives, **Then** the control settles on what is actually in force, and the person is told if the change did not take.
4. **Given** the person changes the same control twice quickly, **When** both answers arrive, **Then** the control ends on the second choice, not on whichever answer was slowest.
5. **Given** a new chat with no agent yet, **When** the person changes an option, **Then** it behaves exactly as it does today, which is already immediate.
6. **Given** an on-or-off option rather than a list, **When** it is switched, **Then** it responds the same way.

---

### User Story 4 - Getting back to the end of the conversation (Priority: P4)

Someone reads back through a long conversation, then wants to return to the live end of it — where the agent is working now and where their next prompt will land. Today the only way back is to scroll, which in a long transcript is a long way, and while they are scrolled up they cannot tell that the agent has said anything new.

**Why this priority**: The conversation is still usable without it — scrolling works — but in a long transcript the cost is high and it is felt on every single read-back. It sits below Stories 1 to 3 because a missing control is a lost capability and a control that lies or lags is worse than one that is absent, whereas this is a slow path to something still reachable.

**Independent Test**: Open a conversation long enough to scroll, scroll well up into it, and confirm both that a way back to the end appears and that taking it lands at the last line, below anything newly arrived.

**Acceptance Scenarios**:

1. **Given** a conversation scrolled away from its end, **When** the person looks at the chat, **Then** a clearly visible way to return to the end is offered.
2. **Given** that affordance is showing, **When** the person takes it, **Then** the view moves to the last line of the conversation and the affordance goes away.
3. **Given** the conversation is already at its end, **When** the person looks at the chat, **Then** no return affordance is shown, because it would do nothing.
4. **Given** the person is scrolled up reading, **When** the agent adds new lines, **Then** the view stays where they are reading and the return affordance indicates that there is something new below.
5. **Given** the person is scrolled up, **When** they send a prompt, **Then** the view returns to the end so they can see their prompt and the reply that follows it.
6. **Given** a conversation of any length, **When** the person uses the keyboard rather than the pointer, **Then** there is a keyboard route to the end of the conversation.

---

### User Story 5 - The mode you chose last time is the mode you get (Priority: P5)

Someone who nearly always works in one particular mode has to change it away from the runtime's default every time they start a chat. The choice does not stick, so the same adjustment is made over and over, and when it is forgotten the agent starts with permissions the person did not intend.

**Why this priority**: It is repeated friction rather than a blockage — the mode can always be set by hand. It depends on Story 1, since a control that is not shown cannot carry a remembered value.

**Independent Test**: Change the mode on a new chat, start it, then begin another new chat with the same runtime and confirm the control opens on the mode chosen last time rather than the runtime's default; quit and reopen the app and confirm it is still remembered.

**Acceptance Scenarios**:

1. **Given** a person who chose a non-default mode when starting a chat, **When** they begin another new chat with the same runtime, **Then** the mode control is already set to the mode they chose last time.
2. **Given** a remembered mode, **When** the app is quit and reopened, **Then** the mode is still remembered.
3. **Given** a remembered mode, **When** the person changes it on a new chat, **Then** the new choice replaces the remembered one for chats that follow.
4. **Given** a remembered mode, **When** the person starts a chat with a different runtime that does not offer that mode, **Then** that runtime's own default is used and no error is shown.
5. **Given** a remembered mode that a runtime has stopped offering, **When** a new chat starts with that runtime, **Then** the runtime's current default is used and the stale value is discarded.
6. **Given** a conversation already under way, **When** the person changes its mode, **Then** only that conversation changes, and the remembered preference for new chats is updated to match.

---

---

### User Story 6 - An agent that wants you to look at something says so (Priority: P6)

An agent working in one conversation puts a file in front of the person — the function it is
about to change, the config that explains the failure. If that conversation is the one on
screen, the file opens in the pane beside it. If it is not, nothing happens anywhere. The
request waits, invisibly, until the person happens to open that conversation, which may be
never. The agent was told the file is open and says so in its reply; the person never finds out
it was asked for.

**Why this priority**: Last by frequency, not by whether it should be done. Showing a file
happens far less often than scrolling or changing a mode, but when it does the signal is
entirely absent rather than merely awkward — and an agent's reply that says "you're looking at
X" when the person is not looking at anything is the app making the agent seem wrong.

**Independent Test**: Start an agent in project A, open a different conversation, and have the
first agent show a file. The first agent should appear as needing attention, and its project
should say so in the sidebar.

**Acceptance Scenarios**:

1. **Given** an agent shows a file while its conversation is not the one on screen, **When** the person looks at the project page, **Then** that agent is shown as needing attention.
2. **Given** that agent is in a project other than the one on screen, **When** the person looks at the sidebar, **Then** that project carries the same needs-attention mark it carries for a permission question.
3. **Given** an agent marked this way, **When** the person opens its conversation, **Then** the file opens in the pane and the mark clears.
4. **Given** an agent shows a file while its conversation **is** on screen, **When** the file opens as it does today, **Then** no mark appears — it has already had the person's attention.
5. **Given** an agent marked this way, **When** it carries on working, **Then** it keeps working. Showing a file does not block it and must not be drawn as though it had stopped.
6. **Given** an agent marked this way, **When** the person sends it a prompt from elsewhere, **Then** the prompt behaves exactly as it does for any working agent — nothing is queued that would not have been.

---

### User Story 7 - Answering a question takes one click (Priority: P7)

An agent asks a question with a short list of answers. The person reads the choices, clicks the
one they want, and then has to find and click **Send** as well. Two clicks to say one word,
while the agent sits blocked waiting for it. A permission question from the same agent, asking
much the same kind of thing, is already one click — the agent's own wording on a row of
buttons — so the app answers two versions of the same question two different ways.

**Why this priority**: Last, because it is one extra click on a form that appears occasionally,
where everything above it is either a lost capability, a lost signal, or friction felt in every
session. It is also the cheapest thing in this feature, so its position here is about value, not
about when it is worth doing.

**Independent Test**: Have an agent ask a question with a single set of choices. Clicking a
choice should answer it outright, with no second click.

**Acceptance Scenarios**:

1. **Given** a question whose whole answer is one choice from a list, **When** the person clicks a choice, **Then** that answer is sent and the question goes.
2. **Given** such a question, **When** the person looks at it, **Then** it reads like the permission questions from the same agent — the agent's own wording, on buttons.
3. **Given** the answer is optional, **When** the person wants to give none, **Then** there is a one-click way to say so.
4. **Given** a question that asks for more than one thing, **When** the person answers part of it, **Then** it keeps its current shape and its Send, because a partial answer cannot be sent.
5. **Given** a question asking for something other than a choice — free text, a number, several at once — **When** it is drawn, **Then** it is unchanged.
6. **Given** any question, **When** the person wants to refuse it entirely, **Then** declining is still one click and still distinct from answering.
7. **Given** a choice has an explanation under it, **When** the choices become buttons, **Then** the explanation is still readable — it is usually the thing that separates two choices.

### Edge Cases

- What happens when the runtime is slow or unreachable while its options are being fetched — how long before the person is told, and can they retry?
- What happens when the person switches runtime or folder on a new chat while the previous fetch is still running, so a stale set of controls could arrive after the new one?
- What happens when the transcript is shorter than the pane, so there is nothing to scroll — the return-to-end affordance must not appear.
- What happens when new lines arrive while the person is scrolled up and then they scroll to the end by hand — the "something new" indication must clear.
- What happens when earlier history is loaded in at the top of a long transcript — the reader's place must be kept, and the return-to-end affordance must remain accurate.
- What happens when a permission request or a form is showing above the prompt, making the floating prompt area taller — the controls and the end of the conversation must both remain reachable.
- What happens when the mode was remembered under a name a newer version of the runtime no longer uses.
- What happens on the very first run, with nothing remembered — the runtime's own default must be used.
- What happens when the project that is clicked has no agents in it at all — the page must still be shown, not skipped.
- What happens when the project clicked is the one whose folder has gone missing — it must still open, and say so there.
- What happens when a project is clicked while an agent in it is mid-turn — the turn must be unaffected by being navigated away from.
- What happens when a question's single choice list is long — a row of buttons must not run off the edge the way the options row does.
- What happens when a choice's wording is long enough to make a button that is mostly text.
- What happens when a question has one choice property that is **not** required — the "no answer" route must still exist and still be one click.
- What happens when the daemon is unreachable at the moment an option is changed — the control must not be left showing a value that never took.
- What happens when a runtime answers an option change with a whole new list of options, including a different value for the one that was just set.
- What happens when an agent shows a second file before the first has been looked at — one mark, not two, and the person sees the latest.
- What happens when an agent that is marked this way is archived, or its folder goes missing — the mark must not outlive the reason for it.
- What happens when an agent shows a file and then finishes its turn before anyone looks — the file is still worth showing, so the mark stays until the conversation is opened.

## Requirements *(mandatory)*

### Functional Requirements

#### The controls under the prompt

- **FR-001**: The area under the prompt MUST always show one of four things: the working controls, a statement that they are being fetched, a statement of what the person must choose first, or a statement that the runtime offers nothing to adjust. It MUST never be silently empty.
- **FR-002**: For a conversation that has already been started, the controls MUST reflect the options that conversation's runtime advertises and MUST show the value currently in force for each.
- **FR-003**: Where a conversation was started but its advertised options are not known to the app, the app MUST obtain them rather than showing nothing.
- **FR-004**: When fetching a runtime's options fails, the person MUST be told, and MUST be able to try again from the chat without restarting the chat or the app.
- **FR-005**: Changing folder or runtime on a new chat MUST cause the controls to be fetched again, and a result arriving for a folder or runtime the person has since moved away from MUST NOT be displayed.
- **FR-006**: All controls MUST remain reachable at every window width the app supports, with no control clipped or pushed out of view.

#### Getting back to a project

- **FR-021**: Clicking a project in the sidebar MUST show that project's page, whether or not that project was already the selected one.
- **FR-022**: FR-021 MUST hold from anywhere in the app, including from inside a conversation belonging to that same project.
- **FR-023**: Reaching a project by keyboard MUST behave the same as reaching it by pointer.
- **FR-024**: Clicking the project whose page is already showing MUST be a no-op — no reload, no flicker, no loss of what is typed in the prompt.
- **FR-025**: Leaving a conversation this way MUST NOT interrupt, cancel or alter whatever the agent in it is doing.

#### Controls that answer at once

- **FR-032**: Choosing a value in an option control MUST update that control immediately, without waiting for the daemon or the runtime.
- **FR-033**: The chosen value MUST stay on screen for as long as the change is in flight.
- **FR-034**: When the answer arrives, the control MUST show what is actually in force, even where that is not what was chosen.
- **FR-035**: Where a change did not take, the person MUST be told, rather than the control silently reverting.
- **FR-036**: Two changes to the same control in quick succession MUST settle on the later choice, whatever order the answers arrive in.
- **FR-037**: FR-032 through FR-036 MUST hold for every kind of control the row draws, including on-or-off ones.

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

#### An agent that wants you to look

- **FR-026**: When an agent shows a file and its conversation is not the one on screen, that agent MUST be presented as needing attention.
- **FR-027**: The project containing that agent MUST carry the same needs-attention mark in the sidebar that it carries for an agent blocked on a question.
- **FR-028**: The mark MUST clear when the person opens that conversation, at the same moment the file opens in the pane.
- **FR-029**: An agent showing a file MUST NOT be presented as having stopped or as being blocked. It is working, and it stays working.
- **FR-030**: Showing a file MUST NOT change what an agent is doing, what it holds, or whether a prompt sent to it is queued.
- **FR-031**: A file shown while its conversation is already on screen MUST behave exactly as it does today, with no mark.

#### Answering in one click

- **FR-038**: Where a question's entire answer is one choice from a list, choosing MUST send the answer — no second action.
- **FR-039**: Such a question MUST be drawn as buttons carrying the agent's own wording, consistent with how a permission question from the same agent is drawn.
- **FR-040**: Where that choice is optional, giving no answer MUST also be one click.
- **FR-041**: A question asking for more than one thing MUST keep its current form and its separate send, because a partial answer cannot be sent.
- **FR-042**: Declining a question outright MUST remain available and MUST remain one click, distinct from answering it.
- **FR-043**: A choice's explanation MUST remain readable when its choice becomes a button.

### Key Entities

- **Mode preference**: The mode the person last chose, held per runtime, outliving any one chat and any one run of the app. Holds the runtime it belongs to and the chosen mode's identifier.
- **Prompt controls state**: What the area under the prompt is currently showing — fetching, nothing chosen yet, nothing offered, failed, or a set of controls — so that it always has something to say.
- **Reading position**: Whether the conversation is at its end or scrolled away from it, and whether anything has arrived since the person scrolled away.
- **Where the window is looking**: Which project is selected and which conversation, if any, is open on top of it. Picking a project is a statement about both.
- **A change in flight**: An option value the person has chosen and the runtime has not yet confirmed. Belongs to one option of one agent, and lasts only until the answer arrives.
- **An unseen request to look**: A file an agent has asked be put in front of the person, which nobody has seen yet. Belongs to one agent, lasts until that conversation is opened, and does not outlive the window.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In every one of the chat states listed in User Story 1's independent test, the area under the prompt shows working controls or a plain explanation — never an unexplained gap. 100% of those states pass.
- **SC-002**: A person can change the agent's mode from within any open conversation without starting a new chat, in every state where the runtime offers modes.
- **SC-003**: Returning to the end of a conversation of any length takes one action, instead of repeated scrolling.
- **SC-004**: A person whose preferred mode differs from the runtime's default makes zero mode changes across their second and subsequent new chats with that runtime.
- **SC-005**: No conversation moves the reader's position on its own while they are scrolled away from the end, across a sustained agent turn.
- **SC-006**: Every control under the prompt is reachable at the app's minimum supported window width.
- **SC-007**: Clicking a project in the sidebar shows that project's page on the first click, from every place in the app it can be clicked from — 100% of cases, including the already-selected project.
- **SC-008**: Every file an agent asks to show is either put in front of the person immediately or marked for them to find — no request goes unannounced.
- **SC-009**: No agent is shown as blocked, stopped or waiting on account of having shown a file.
- **SC-010**: An option control shows the person's choice within one frame of the click, on every runtime, however busy it is.
- **SC-011**: A question whose answer is a single choice is answered in one click, down from two.

## Assumptions

- "Controls below the prompt input" means the row of option controls — mode, model, effort, permissions, and reach — that sits beneath the text field, not the send, attach, and dictate buttons inside the field itself.
- The mode preference is remembered per runtime. Modes are runtime-specific, so a mode chosen for one runtime is usually meaningless to another; a single global preference would fall back to the default most of the time.
- The mode preference is not scoped per folder or per project. This is the most likely thing to want differently, and is the first candidate for `/speckit-clarify`.
- Remembering applies to new chats. A conversation already under way keeps whatever mode it is running with until the person changes it there.
- The preference lives on the machine the app runs on, alongside the other window and selection preferences, rather than being held centrally or synced between machines.
- Existing behaviour that is already right is kept: a conversation opens at its end, follows itself while the reader is at the end, and keeps the reader's place when earlier history is loaded in.
- No new option is invented. "Mode" is whichever option the runtime already advertises under that heading; runtimes that advertise none are unaffected.
- The back control in the toolbar stays exactly as it is. It is the documented way out of a conversation and this feature adds a second route rather than replacing it.
- Clicking a project is a statement about where the window is looking, not about the work. No agent is stopped, started or altered by it.
- An unseen request to look does not outlive the window. The daemon already refuses to show a file when no window is open, and already stores nothing — "a file worth looking at now is not worth reopening a week from now". This feature does not reverse that.
- "Needs attention" covers both being blocked on the person and wanting the person's eyes. They are different urgencies, but they are the same answer to "where should I look next", which is what the mark is for.
- An option change that is in flight is not persisted anywhere. If the app is quit mid-change, what is in force is whatever the runtime settled on.
- "One click" applies to questions whose whole answer is a single choice. A question asking for several things cannot be answered in one click and is out of scope.
- A single on-or-off question could be made one-click by the same argument. It is not included here, because the request named the choice list; it is the obvious next thing if this reads well.
- The seven fixes are independent and can ship separately, in priority order.
