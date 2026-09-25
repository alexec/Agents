# Feature Specification: Park a Chat to Come Back To Later

**Feature Branch**: `040-parked-chats`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Parked chats. Sometimes I have finished with a chat for the moment and want to come back to it later. I don't want to archive it. I want to park it."

## Why this feature exists

A project's session list sorts chats by how they last ended: Needs attention, Working, Complete,
Stopped. Beneath those is a folded Archived list. Once a chat is out of the way, it can only go to
one of two places. It can stay in its group, where it keeps asking for a look it is not going to
get today. Or it can go to the archive, which says *this is over* and folds it out of sight.

Many chats are neither. The person has read the answer, the work is half-merged or waiting on
something in their head, and they mean to pick it up tomorrow or next week. Left in Needs attention
or Complete, such a chat buries the chats that do want them now. Archived, it is lost: out of sight
is out of mind, and the archive is where finished things go, not unfinished ones. Its worktree is
also treated as free to remove.

This feature adds a third place: **Parked**. A parked chat is put down on purpose, to come back
to. It sits in its own group, always visible, below the others. It asks nothing of the person
while it is there and never wakes itself. Coming back is opening it and carrying on.

## Clarifications

### Session 2026-09-24

- Q: Where does a parked chat sit in the project's session list? → A: In a Parked group of its own, always shown, below Stopped and above the folded Archived list.
- Q: Does a parked chat ever come back by itself? → A: No. It stays parked until the person unparks it or sends it a prompt. There is no "park until" time.
- Q: What happens if the person parks a chat while the agent is still working? → A: The turn runs to its end, and the chat goes to Parked when it finishes. Nothing is cut off.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Park a chat I've finished with for now (Priority: P1)

Someone has read what an agent came back with. They mean to return to it but not today. In the
chat's toolbar, beside Archive, there is a Park button. They click it. The chat leaves Complete (or
Needs attention, or Stopped) and appears in a Parked group near the bottom of the project's list.
Nothing about the conversation changes. It is still there, whole, one click away, and it no longer
competes with the chats that want them now.

**Why this priority**: It is the whole of the request. Every other story builds on a chat being
parked.

**Independent Test**: Take a finished chat, park it from its toolbar, and check that it now appears
under Parked and nowhere else. Its transcript, cost, worktree and model are unchanged. Restart the
app and the daemon, and check it is still under Parked.

**Acceptance Scenarios**:

1. **Given** a chat that is finished, stopped or waiting in Needs attention on a report, **When** its chat is open, **Then** a Park button is shown in the toolbar beside Archive.
2. **Given** that button, **When** the person clicks it, **Then** the chat appears in the Parked group of its project and in no other group, and the page goes back to the project, as it does after Archive.
3. **Given** a chat's card in the session list, **When** the person opens its menu, **Then** Park is offered there too.
4. **Given** a project with at least one parked chat, **When** its session list is shown, **Then** a Parked heading with a count is shown below Stopped and above Archived. Its chats are listed beneath it without anything to unfold.
5. **Given** a project with no parked chats, **When** its session list is shown, **Then** no Parked heading is shown.
6. **Given** a parked chat, **When** its row is read, **Then** it shows its title, how long ago it was parked, and how it last ended. It does not show a needs-attention or unread mark.
7. **Given** a parked chat, **When** the app or the daemon restarts, **Then** it is still parked.

---

### User Story 2 - Come back to a parked chat (Priority: P1)

Some days later the person opens the Parked group, clicks the chat, and reads it again. Opening it
leaves it parked, so they can check something and put it straight back down. When they are ready
to carry on, they either type a prompt, which unparks it and starts the agent, or click Unpark,
which puts it back where it belongs without saying anything to the agent.

**Why this priority**: Parking something you cannot easily get back is archiving. Coming back is
the other half of the same request.

**Independent Test**: Park a chat. Open it and leave, and check it is still parked. Send it a prompt
and check it runs and is no longer parked. Park another, click Unpark, and check it returns to the
group its ending puts it in, without the agent being prompted.

**Acceptance Scenarios**:

1. **Given** a parked chat, **When** the person opens it, reads it and leaves, **Then** it is still parked.
2. **Given** a parked chat is open, **When** the page is shown, **Then** it says the chat is parked, and an Unpark button stands where Park was.
3. **Given** a parked chat, **When** the person sends it a prompt, **Then** it is unparked and the agent starts the turn, as with any other chat.
4. **Given** a parked chat, **When** the person clicks Unpark (in the toolbar or the card's menu), **Then** it returns to the group its last ending puts it in. The agent is not prompted, and nothing is added to its conversation.
5. **Given** a parked chat, **When** the person archives it, **Then** it goes to Archived and is no longer parked. Unarchiving it later returns it to the group its ending puts it in, not to Parked.

---

### User Story 3 - Park a chat that is still working (Priority: P2)

The person has seen enough of a turn in progress to know they will not look at the result today.
They click Park while the agent is still working. The turn is not cut short. The chat is marked as
parking when it ends. When the turn finishes, stops or fails, the chat goes to Parked instead of
landing in Complete or Needs attention.

**Why this priority**: It saves waiting for a turn to end just to put the chat down. But the common
case is a chat that has already ended, which Story 1 covers.

**Independent Test**: Start an agent on a task that takes a minute and click Park at once. Check
it keeps working to the end with no stop in its transcript, that its row says it will park, and
that when it ends it is under Parked and not in Complete or Needs attention, and raises no
needs-attention alert.

**Acceptance Scenarios**:

1. **Given** a chat whose agent is starting or working, **When** the person clicks Park, **Then** the turn carries on to its end, and the chat stays under Working, marked as parking when the turn ends.
2. **Given** such a chat, **When** its turn ends by any means (done, stopped, failed, or with a report that asks for the person), **Then** it goes to Parked and raises no needs-attention alert, badge or notification.
3. **Given** a chat marked to park when its turn ends, **When** the person clicks Unpark before the turn ends, **Then** the mark is withdrawn and the chat ends in the group it would have without it.
4. **Given** a chat marked to park when its turn ends, **When** the agent stops mid-turn to ask the person a question, **Then** the question is shown and waits exactly as it does today, because the turn has not ended. The chat parks when the turn does end.
5. **Given** a chat marked to park when its turn ends, **When** the person sends it another prompt, **Then** the mark is withdrawn, as sending a prompt to a parked chat unparks it.

---

### User Story 4 - Park and come back from the phone and iPad (Priority: P3)

The person is away from the Mac and clearing their list from the phone. The chat's menu offers
Park and Unpark. The project's list on the phone shows the same Parked group as the Mac, holding the
same chats.

**Why this priority**: The phone is where people triage. But the Mac is where parking will be used
most, and the feature is whole without the phone.

**Independent Test**: Park a chat on the Mac and check it is under Parked on the phone. Unpark it
from the phone and check it has left Parked on the Mac.

**Acceptance Scenarios**:

1. **Given** a chat that can be parked, **When** its menu is opened on the phone or iPad, **Then** Park is offered. For a parked chat, Unpark is offered.
2. **Given** a chat parked on either device, **When** the other shows the project's list, **Then** the chat is under Parked there too.
3. **Given** the phone has lost touch with the Mac, **When** the chat's menu is opened, **Then** Park and Unpark are shown but disabled, as the phone's other actions already are.

---

### Edge Cases

- **Parking a chat whose last report asks for the person** (needs an answer, partly done, stuck). It leaves Needs attention and goes to Parked. That is the point: the person has seen it and chosen later. Its report is kept and shown again once it is unparked.
- **A chat that asked the person to look at a file.** Parking it clears its claim on their attention in the same way.
- **Park is clicked twice, or on a chat already parked.** Nothing changes, and no error is shown.
- **A parked chat's worktree.** Removing the worktree is refused while a parked chat uses it, just as for any other chat that is not archived. Parking is not putting the work away.
- **A chat started by another agent** (028). The person can park it like any other chat. Parking an agent does not park the agents it started, or the agent that started it.
- **Agents managing agents.** An agent cannot park or unpark a chat. Parking is the person's word about their own attention.
- **A workflow's agent.** Parking it does not change the workflow, and fires no workflow trigger. When a chat marked to park ends its turn, the triggers that watch for an agent finishing or stopping fire as they would have without the mark.
- **A chat marked to park is being brought back after a restart.** It keeps the mark. It is picked up as it would be today, and parks when that turn ends.
- **A project is archived.** Its parked chats go with it, the same as its other chats.
- **Many parked chats.** The Parked group lists them all, most recently parked first. It does not fold away. If it grows long, the person archives from it.
- **Cost and spending.** A parked chat's cost still counts toward its project and the spending totals, the same as any other chat.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The person MUST be able to park any chat that is not archived, from the chat page's toolbar and from its card's menu on the Mac.
- **FR-002**: A parked chat MUST appear in its project's Parked group and in no other group. Being parked MUST NOT change how the chat last ended, its report, transcript, cost, model, options, queued prompts or worktree.
- **FR-003**: The Parked group MUST be shown below Stopped and above the folded Archived list, whenever the project has at least one parked chat. It MUST be always open, with its count in the heading, and list its chats most recently parked first.
- **FR-004**: A parked chat MUST NOT count toward Needs attention anywhere: the group, the project's counts, the app's badges, or notifications to the person.
- **FR-005**: Parking MUST NOT prompt, stop or otherwise touch the agent, and MUST NOT add anything to its conversation.
- **FR-006**: Parking a chat whose agent is starting or working MUST let the turn run to its end, and MUST mark the chat as parking when the turn ends. When the turn ends by any means, the chat MUST go to Parked, and that ending MUST NOT raise a needs-attention badge or notification.
- **FR-007**: A parked chat MUST stay parked when it is opened and read, and when the app or daemon restarts. Only the person can unpark it. It MUST NOT unpark on its own, by time or by any agent's action.
- **FR-008**: The person MUST be able to unpark a chat from the chat page and from its card's menu. Unparking MUST return the chat to the group its current state and ending put it in, and MUST NOT prompt the agent. Unparking a chat marked to park when its turn ends MUST withdraw the mark.
- **FR-009**: When the person sends a prompt to a parked chat, or to one marked to park when its turn ends, the chat MUST be unparked (or the mark withdrawn), and the prompt MUST then be handled as for any other chat. A prompt the app sends by itself, such as a workflow's or an outcome question, MUST NOT unpark it.
- **FR-010**: Archiving a parked chat MUST unpark it. Unarchiving MUST NOT restore the parked status.
- **FR-011**: A parked chat's page MUST say that it is parked and when it was parked. Its row MUST show how long ago it was parked.
- **FR-012**: Whether a chat is parked, or marked to park when its turn ends, MUST be kept by the daemon. The Mac, the phone and the iPad MUST all show the same answer. Which chats can be parked and unparked MUST be decided in one place that every device reads.
- **FR-013**: The phone and iPad MUST offer Park and Unpark in the chat's menu, and MUST show the Parked group in a project's list in the same place as on the Mac.
- **FR-014**: A worktree used by a parked chat MUST be treated as in use, the same as one used by any other chat that is not archived.
- **FR-015**: Parking or unparking MUST NOT fire any workflow trigger. The triggers for an agent finishing or stopping MUST fire as they do today, whether or not the chat was marked to park.
- **FR-016**: Agents MUST NOT be able to park or unpark any chat through the tools the app gives them.
- **FR-017**: Parking or unparking a chat that is already in that state MUST change nothing and show no error.
- **FR-018**: The Park and Unpark controls MUST carry a tooltip and an accessibility label saying what they do, and use the same words and symbol on every device.

### Key Entities

- **Parked mark**: a fact about a chat, kept alongside how it last ended and not in place of it. It records that the person put the chat down to come back to, and when. It has three values: not parked, parking when the turn ends, and parked.
- **Parked group**: the heading a project's list draws parked chats under. It is worked out from the chat's parked mark and never stored separately, so a chat is always in exactly one group.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From an open chat, a person can park it in one click, and bring it back in one click or by typing a prompt.
- **SC-002**: A parked chat is never shown in Needs attention and never raises a badge or notification. This is checked by parking chats with each kind of ending and report.
- **SC-003**: No parked chat unparks without the person across restarts of the app, the daemon and the Mac. That is zero across repeated trials.
- **SC-004**: A chat parked while working finishes its turn with nothing cut off, and lands in Parked within 5 seconds of the turn ending.
- **SC-005**: The Mac, phone and iPad agree on which chats are parked within 2 seconds of any change.
- **SC-006**: The person no longer has to archive a chat they mean to come back to, or leave it in Needs attention or Complete, just to keep their list readable.

## Assumptions

- Parking is not a new way for a chat to end, and it is not a new agent state. It sits on top of how the chat ended, so unparking puts it back exactly where it would have been.
- The swipe on a card stays Archive. Park is reached from the chat toolbar and the card's menu. Adding it to the swipe can come later, once the button has been used.
- There is no keyboard shortcut for Park in this feature.
- Parking from the chat page goes back to the project, as Archive does, because the person has said they are done with it for now. A chat parked while working also goes back. It will land in Parked when its turn ends.
- A question the agent asks mid-turn is part of that turn, so a chat marked to park still shows it under Needs attention until it is answered. Parking does not answer or cancel questions.
- Parking is per chat. There is no "park all" or parking a whole project in this feature.
- The Blocked group proposed in 039 is separate. A blocked chat can be parked, and then it sits in Parked. If its block clears and the app prompts it, that prompt comes from the app, not the person, so it does not unpark the chat. It runs, and lands back in Parked. (To be confirmed against 039 when both are planned.)
