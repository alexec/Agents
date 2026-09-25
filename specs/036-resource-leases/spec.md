# Feature Specification: Agents Take Turns With the Mac's Shared Things

**Feature Branch**: `036-resource-leases`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Resource leases. The ability for agent to get a lease on a system resource, so resource sharing becomes easier. Resources can be identified by the system resources, simulator, browsers, etc. This can allow mulitple agents to share resource access. This will need a tool to lease/release resources. A UI to monitor usage of resources. Status line in chats and on the chat card to show the resources leased by the agent. Time based leases, and automatic starting of an agent when a lease is requested (I think the MCP tool can block?)."

## Why this feature exists

Several agents now run on the same Mac at once, and some of what they use there can only be used
by one of them at a time. Two agents booting the same simulator, driving the same browser window,
clicking in the app in front of the person, or starting a server on the same port get in each
other's way. What goes wrong is rarely a clean error. Usually it's a wrong screenshot, a click that
lands in the other agent's window, or a test that fails for a reason nobody can see afterwards.

Today agents have no way to tell each other "I'm using this". Each one finds out by colliding.
The person finds out by reading two transcripts side by side. The workaround so far has been rules
agents are told to follow ("drive the scratch app only when Alex is away", "never create a
throwaway simulator"). Those rules don't say who is using something now, and nothing makes an
agent wait its turn.

This feature gives agents a shared way to take turns. An agent asks the app for a lease on a named
thing, holds it while it works, and gives it back. If someone else holds it, the agent waits in
line. When the thing is free, the agent is let through. That happens even if it has stopped and
has to be started again. The person can see who holds what and who is waiting, both in one place
and on each agent's chat and card. They can end any lease, and take anyone out of a line. They
never hold a lease themselves: only agents do.

## Clarifications

### Session 2026-09-24

- Q: When an agent's turn ends while it still holds a lease, what happens? → A: The lease is kept until it expires. It is also released on release, stop, archive, or when the person ends it. The end of a turn never releases it.
- Q: How much goes on the phone and iPad? → A: The status line and card only. The Resources view, and ending leases, are on the Mac only for now.
- Q: Can the person hold a lease? → A: No. Only agents hold leases. There is no way in the app to take one. The person can end an agent's lease and remove an agent from a line.
- Q: Is a lease chosen when a chat is started? → A: No. Starting a chat, on the Mac, phone or iPad, or by an agent through `start_agent`, has no lease option. The agent takes a lease itself, with its tools, when it needs one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent takes a lease, works, and gives it back (Priority: P1)

An agent that is about to use the simulator asks for a lease on it. The simulator is free, so the
agent gets the lease straight away and learns when it expires. It does its work and releases the
lease. While it holds the lease, a line on its chat and on its card says what it holds.

**Why this priority**: Everything else is built on this. Even alone, an agent that takes and
returns a lease tells every other agent, and the person, what it is using.

**Independent Test**: Ask an agent to lease the simulator, wait a moment, then release it. Confirm
it is told it holds the lease and until when, that its chat and card show it while held, and that
both clear when it releases.

**Acceptance Scenarios**:

1. **Given** a resource nobody holds, **When** an agent asks for a lease on it, **Then** it gets the lease at once and is told its expiry.
2. **Given** an agent holding a lease, **When** it releases the lease, **Then** the resource is free and the agent's chat and card stop showing it within a second.
3. **Given** an agent holding a lease, **When** it asks to extend the lease before expiry, **Then** the expiry moves forward and it is told the new one.
4. **Given** an agent that asks for a lease on something it already holds, **When** the request arrives, **Then** it is treated as an extension, not as a second lease, and the agent never waits on itself.
5. **Given** an agent, **When** it asks which leases it holds, **Then** it is told each one and its expiry.

---

### User Story 2 - A second agent waits its turn and is let through (Priority: P1)

A second agent asks for the simulator while the first holds it. It waits in line. When the first
agent releases the lease, or the lease runs out, the second agent gets it and carries on. If the
second agent's wait outlasted its turn, the app starts the agent again with the lease already in
hand.

**Why this priority**: This is the reason for leases. Without waiting, a lease is only a sign on
the door and every agent has to poll and retry.

**Independent Test**: Have agent A lease the simulator. Have agent B ask for it, then release A's
lease. Confirm B is granted it and continues. Repeat with A holding it longer than B's wait can
last. Confirm B is told it is in line and its turn ends. When A releases, confirm B is started again
with the lease and is told it now holds it.

**Acceptance Scenarios**:

1. **Given** a resource held by agent A, **When** agent B asks for it, **Then** B is told who holds it and B's place in line, and B waits.
2. **Given** B waiting, **When** A releases the lease or it expires, **Then** B is granted it within a second and its request returns as if the resource had been free.
3. **Given** B waiting longer than a request can be held open, **When** that limit is reached, **Then** B's request returns saying B is still in line, B's place is kept, and B can end its turn.
4. **Given** B's turn has ended while it is in line, **When** the lease comes to B, **Then** the app starts B again with a prompt saying it now holds the lease and how long it has. The prompt appears in B's transcript like any prompt the app sends.
5. **Given** several agents in line, **When** the resource comes free, **Then** it goes to the one that asked first.
6. **Given** an agent in line, **When** it withdraws its request, is stopped, or is archived, **Then** it leaves the line and the next agent moves up.
7. **Given** an agent that doesn't want to wait, **When** it asks with "don't wait", **Then** it is told at once whether it got the lease, and if not, who holds it and until when.

---

### User Story 3 - The person sees who holds what (Priority: P1)

The person opens a Resources view and sees every resource the app knows about. For each one it
shows whether the resource is free, who holds it and since when, when the lease expires, and who is
waiting. Each agent's chat has a status line listing the leases it holds and any it is waiting
for. Each agent's card shows the same thing briefly.

**Why this priority**: Leases the person can't see would only move the confusion around. The
person needs to see why an agent is waiting, and which agent is in the way.

**Independent Test**: With one agent holding the simulator and another waiting, open the Resources
view. Confirm both agents appear against the simulator: holder, expiry, and the waiting agent. Open
each agent's chat and look at each card. Confirm the holder shows it holds the simulator and the
waiter shows it is waiting for it.

**Acceptance Scenarios**:

1. **Given** leases held and requested, **When** the person opens the Resources view, **Then** each resource shows free or held, the holder, when the holder took it, when it expires, and the line in order.
2. **Given** an agent holding one or more leases, **When** the person looks at its chat, **Then** a status line names each resource it holds with the time left.
3. **Given** an agent waiting for a lease, **When** the person looks at its chat or card, **Then** it shows what the agent is waiting for, who holds it, and the agent's place in line.
4. **Given** the Resources view, the status line, or a card, **When** a lease is granted, released, extended or expires, **Then** what is shown changes within a second without the person doing anything.
5. **Given** a holder or waiter shown in the Resources view, **When** the person selects it, **Then** that agent's chat opens.
6. **Given** the phone or iPad app, **When** the person looks at an agent's chat or card, **Then** it shows the same leases and waits as the Mac. The Resources view itself is on the Mac only.

---

### User Story 4 - The person takes a lease back (Priority: P2)

If an agent is holding something it should not, the person can end that agent's lease at once. If
an agent is waiting for something it no longer needs, the person can take it out of the line. The
person never holds a lease themselves.

**Why this priority**: The person is the one most harmed by an agent clicking in the wrong window.
Ending a lease by hand is the way out when an agent holds something and has stopped paying
attention. It depends on Stories 1–3.

**Independent Test**: Have agent A lease the screen and agent B ask for it. End A's lease from the
Resources view. Confirm the agent is told its lease was ended by the person, and
the next agent in line gets the resource.

**Acceptance Scenarios**:

1. **Given** a free resource in the Resources view, **When** the person looks at it, **Then** there is no way to take it. Only agents hold leases.
2. **Given** any lease, **When** the person ends it, **Then** the resource passes to the next in line at once, and the agent that lost it is told the person ended its lease the next time it uses any lease tool. It is not interrupted mid-turn.
3. **Given** anyone in line, **When** the person removes them from the line, **Then** they leave it as if they had withdrawn.

---

### User Story 5 - Leases don't outlive their use (Priority: P2)

Every lease has an end. A lease that runs out, or whose agent is stopped or archived, frees its
resource without anyone doing anything. Nothing stays locked because an agent forgot, crashed, or
the app restarted.

**Why this priority**: The main risk of any locking scheme is a lock nobody releases. Time limits
exist to make that impossible.

**Independent Test**: Have an agent take a short lease and let it expire. Confirm it frees on time
and the next in line gets it. Have an agent take a lease, then stop the agent. Confirm it frees.
Have an agent take a lease, restart the app, and confirm the lease is still there with the same
expiry.

**Acceptance Scenarios**:

1. **Given** a lease, **When** its expiry passes without an extension, **Then** it is released and the next in line is granted the resource.
2. **Given** an agent holding leases, **When** it is stopped or archived, **Then** all its leases are released and it leaves every line it was in.
3. **Given** an agent holding a lease, **When** its turn ends without releasing it, **Then** the lease stays until it is released or expires, the agent is stopped or archived, or the person ends it. The status line keeps showing it, so the person can see an idle agent holding something.
4. **Given** leases held and lines waiting, **When** the app or its background service restarts, **Then** each lease and line is kept with the same expiry, and a lease that expired during the restart is released as soon as the app is back.
5. **Given** a lease about to expire, **When** a set warning time before its expiry arrives and the holder is still working, **Then** the holder is told the next time it uses a lease tool, and the Resources view marks the lease as ending soon.

---

### User Story 6 - The resources are ones the app already knows (Priority: P3)

When an agent or the person leases something, they pick from resources the app has found on this
Mac: each simulator, each browser, the Mac's screen and keyboard. They don't have to invent a name
and hope every other agent spells it the same way. An agent can still lease a name of its own for
something the app doesn't know about, such as a port or an account.

**Why this priority**: A known list makes two agents collide on the same name rather than miss
each other. Named-by-hand leases alone already make the feature work, so this can come later.

**Independent Test**: Ask an agent to list resources. Confirm it sees the Mac's simulators,
installed browsers, and the screen, each with a name and whether it is free. Lease one by that
name. Lease a made-up name and confirm that works too and appears in the view as named by an agent.

**Acceptance Scenarios**:

1. **Given** the Mac, **When** an agent or the person lists resources, **Then** they see each simulator the Mac has (by device and system version), each installed browser, and the screen, each with its state.
2. **Given** a name that isn't in the list, **When** an agent leases it, **Then** the lease works like any other, the resource appears in the view while leased or requested, and it disappears once nobody holds it or waits for it.
3. **Given** names that differ only in upper and lower case or surrounding spaces, **When** they are leased, **Then** they are treated as the same resource.

---

### Edge Cases

- **Two agents ask for a free resource at the same moment.** One gets it and the other waits. It is never held by two at once.
- **An agent asks for two resources, one of them held.** Each lease is asked for separately. The spec does not provide all-or-nothing requests for several resources. The tool's description tells agents to request resources in a steady order to avoid holding one while waiting for another.
- **A waits for B's resource while B waits for A's.** Neither is ever stuck for good, because every lease expires. The Resources view shows both waits, so the person can see the loop and end one of the leases.
- **A waiting agent is started again, but the person has sent it a prompt in the meantime.** The app's prompt is sent after the agent's current turn, not in the middle of it. The lease is held for it from the moment it is granted, and the clock starts then.
- **A waiting agent is started again, but it can't run** (its runtime is gone, its project was removed, or it hit a spending limit). The lease is released and passed on, and the agent's transcript says why.
- **The simulator or browser disappears from the Mac while leased.** The lease stays until released or expired, and the view marks the resource as gone.
- **The holder uses the resource without a lease, or another agent does.** Nothing stops it. Leases are an agreement between agents, not a lock on the device (see Assumptions).
- **An agent asks for a lease longer than the longest allowed.** It gets the longest allowed and is told so.
- **An agent started by another agent (028) asks for a lease.** It is treated like any agent.
- **An agent in a worktree (030) asks for a resource.** Leases are Mac-wide, so a worktree agent and the main project's agents share one line.
- **A scratch copy of the app runs on its own root.** Its leases are its own. They are not shared with the real app, just as its agents are not.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST give every agent tools to lease a resource, release a lease, extend a lease, withdraw from a line, list its own leases and waits, and list resources with their state.
- **FR-002**: A resource MUST be held by at most one holder at a time, however many requests arrive together.
- **FR-003**: A lease request MUST name the resource, and MAY give a duration and a "don't wait" choice. With no duration, the lease MUST last for a default of 30 minutes. No lease MUST last longer than a maximum of 4 hours without an extension.
- **FR-004**: A request for a held resource MUST, unless "don't wait" is given, put the requester in line in order of asking and keep the request open until the lease is granted or a waiting limit is reached. The waiting limit MUST be short enough that no runtime gives up on the call first.
- **FR-005**: When a request reaches its waiting limit, it MUST return saying the agent is still in line, with its place and the current holder, and the agent MUST keep its place.
- **FR-006**: When a lease is granted to an agent whose request is no longer open, the app MUST start that agent again with a prompt saying which lease it now holds and until when. This MUST happen whether or not the agent is running, and without asking the person.
- **FR-007**: A lease MUST be released when its holder releases it, when it expires, when the holder is stopped or archived, or when the person ends it. The end of the holder's turn MUST NOT release a lease. On release the resource MUST pass to the next in line.
- **FR-008**: Leases, lines and their order MUST survive a restart of the app and its background service.
- **FR-009**: The app MUST have a Resources view showing every known resource and every resource currently leased or requested. For each it MUST show the state, the holder, the time held, the expiry, and the line in order. It MUST update within a second of any change.
- **FR-010**: Each agent's chat MUST show a status line naming each lease it holds with the time left, and each lease it is waiting for with the holder and its place in line. Each agent's card MUST show the same thing in short form. Both MUST show nothing when the agent holds and waits for nothing.
- **FR-011**: The phone and iPad apps MUST show the status line and card information. The Resources view, and the person's power to end leases and to remove anyone from a line, are on the Mac only in this feature.
- **FR-012**: The person MUST be able to end any lease and remove anyone from a line, from the Resources view. The person MUST NOT be able to take a lease: only agents hold leases. An agent whose lease the person ended MUST be told so the next time it uses a lease tool.
- **FR-013**: The app MUST find the Mac's simulators, its installed browsers and its screen as resources, each under a stable name, and MUST also accept any other name an agent gives, compared without regard to case or surrounding spaces.
- **FR-014**: Every refusal or wait MUST be explained in plain words the agent can repeat to the person: who holds the resource, until when, and the agent's place in line.
- **FR-015**: The briefing an agent receives MUST describe the lease tools and when to use them. It MUST say to lease a known resource before using it, release it as soon as it is done, keep leases short and extend them, and take several resources in a steady order.
- **FR-016**: An agent's transcript MUST record each lease it was granted, released, lost to expiry, or had ended by the person, so the history can be read afterwards.
- **FR-017**: Starting an agent MUST NOT offer any way to lease a resource for it: not the start form on any platform, and not the `start_agent` tool. An agent MUST take its leases itself, through the lease tools, when it needs them.

### Key Entities

- **Resource**: Something on the Mac that one agent uses at a time. It has a stable name and a kind (simulator, browser, screen, or named by an agent). It is either found by the app or created by an agent's request. It is free or held, and has a line.
- **Lease**: One holder's right to a resource for a period. It has a holder, a resource, when it was granted, when it expires, and how it ended (released, expired, ended by the person, holder stopped or archived).
- **Holder**: Always an agent. The person never holds a lease.
- **Line**: The ordered requests waiting for a resource. Each request has the agent, when it asked, and whether its call is still open or the agent will need starting again.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across repeated trials of agents asking for the same resource at the same moment, no resource is ever held by two holders at once.
- **SC-002**: When a lease is released or expires, the next agent in line is granted the resource within 1 second if its request is open, and is started again within 5 seconds if not.
- **SC-003**: No lease survives more than 5 seconds past its expiry or its holder being stopped or archived, including across a restart.
- **SC-004**: A person looking at any agent's chat or card can tell what it holds and what it is waiting for without opening anything else.
- **SC-005**: A person opening the Resources view can name the holder of any resource, and everyone waiting for it, within 5 seconds.
- **SC-006**: Two agents told to test on the simulator at the same time finish both runs without one run's screenshots or taps landing in the other's.

## Assumptions

- **Leases are an agreement, not a lock.** The app doesn't stop an agent, or the person, from using a simulator or browser it doesn't hold. Agents that follow their briefing use leases, and the gain is that they no longer collide. Enforcing leases on devices is out of scope.
- **"Starting an agent when a lease is requested" means waking the waiting agent.** An agent that asked for a lease is started again when the lease reaches it. This spec doesn't create new agents to use freed resources.
- **The request call waits, but only for a while.** A tool call can wait for the lease, as the description guessed. How long a runtime waits before giving up varies and isn't under the app's control, so the call returns after a limit and the app starts the agent again when the lease comes. That makes waiting work the same on every runtime.
- **Leases cover the whole Mac, not one project.** A simulator is one simulator whichever project's agent uses it.
- **Only single leases.** Shared or counted leases (several holders at once, or "any one of three simulators") are out of scope. Two simulators are two resources.
- **Workflows see lease events as nothing new.** An agent started again for a lease runs its turn like any other, and the project's workflows fire on it as usual. New workflow triggers for lease events are out of scope.
- **The defaults (30 minutes, a 4-hour maximum, a warning 5 minutes before expiry) are chosen here** and can be moved into settings later. They are not asked about.
- **The screen resource stands for the Mac's front window, mouse and keyboard.** It is what an agent should hold before clicking or typing into any app, including a scratch copy of this one.
