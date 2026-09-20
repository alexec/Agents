# Feature Specification: The iPad Remote

**Feature Branch**: `013-ipad-app`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "the iPad app"

**Clarified 2026-09-19**: "Both the iPad and the iPhone still act as remote controls to the primary application. What I really want to do here is get the iPad and iPhone both working, but I want to just start with the iPad and will work on the iPhone later on. So the main thing we're going to need to do is to be able to get escalations from the user in terms of notifications that the user can actually answer from the screen. Then we're going to need to be able to go into the project, see project, see agent, see work — both see all the information that is available on the desktop app — but the actual work and the daemon stays on the Mac."

## Why this feature exists

Feature 005 wrote down both remotes in full and then largely did not get built: twenty of
its eighty-six tasks are done. What exists today is an iOS app that finds the Mac on the
same network through a bridge somebody has to start by hand, with no pairing, no sealing,
no notifications, and no way to reach the Mac from anywhere else. The half that was
written down first and matters most — being asked, wherever you are, and being able to
answer — is exactly the half that is not there.

So this feature is not new ground. It is 005's promise, delivered, on one device on
purpose. **The iPad first; the iPhone after.** Two devices at once means two layouts to
judge, two sets of notification behaviour to test and two ways for every bug to be
hardware-specific, and the likely outcome is a feature ninety per cent done on both rather
than finished on one. Nothing here is built in a way that shuts the iPhone out — it is the
same app and the same code — it is simply not what gets carried to done this time.

Two things make it worth having. The first is the escalation: an agent stops dead waiting
for one word, and today that word can only be said at the Mac. A notification the person
can answer from the screen in front of them — without unlocking into an app, without
going back to the desk — turns a stalled afternoon into a five-second interruption. The
second is being able to look: to open the project, find the agent, and read the work with
everything the Mac's window would have shown, rather than a summary of it.

**The work does not move.** Agents run in the daemon on the Mac, as they do now. The iPad
runs nothing, owns nothing and stores nothing to work from. It is a way of being asked and
a way of looking.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Being asked, and answering from where you are (Priority: P1)

The iPad is on the side of the desk, or in another room, or in a bag on a train. An agent
on the Mac stops and asks for permission to run a command. The iPad buzzes. The
notification names the project, names the agent, and says what is wanted. The person reads
it and allows it — from the notification itself, without unlocking into the app. The agent
carries on. When what is being asked is too big to decide from a banner, tapping it opens
straight onto that question with everything needed to decide.

**Why this priority**: This is the feature. It is the thing 005 existed for and the thing
that is not built. On its own, with nothing else in this spec, it already turns the Mac
from something the person must sit at into something that can be left running. It is worth
shipping even if the iPad could do nothing else at all.

**Independent Test**: With the iPad locked and the app not running, provoke a permission
request on the Mac. Confirm the notification arrives, names the right things, and can be
answered from the notification. Confirm the agent continues on the Mac and that the Mac's
own window shows the question answered rather than still pending.

**Acceptance Scenarios**:

1. **Given** a paired iPad and an agent on the Mac that asks for permission, **When** the
   request is raised, **Then** the iPad is notified promptly, naming the project, the agent
   and what is being asked.
2. **Given** the notification on screen, **When** the person answers it there, **Then** the
   answer reaches the Mac, the agent carries on, and the app never had to be opened.
3. **Given** the notification offers the common choices, **When** what is being asked
   cannot be decided from a banner — a change to read, a form to fill — **Then** the
   notification says so and opening it lands on that question in full.
4. **Given** the question is answered, **When** the Mac's window is looked at, **Then** it
   shows the question answered, and by which device, not still pending.
5. **Given** a question already answered at the Mac, **When** the iPad's notification is
   opened, **Then** it shows what became of it and offers no second answer.
6. **Given** an agent asks a form question rather than a permission, **When** it is raised,
   **Then** the iPad is notified in the same way and the form can be answered from the app.
7. **Given** notifications for finishing and for failing, **When** the person does not want
   them, **Then** each kind can be turned off independently without turning off the
   escalations.
8. **Given** the app is open when the question is raised, **When** it appears, **Then** it
   appears in the app too, and answering in either place settles it once.

---

### User Story 2 - Everything the Mac shows about the work (Priority: P2)

The person opens the app and goes project, agent, work. They read what the agent has
actually done: what they asked, what it replied, what it ran and what came back, what it
changed and how, what it plans to do next, what it has cost and how much of its context is
gone. Nothing is a summary of something richer that is only on the Mac. If the Mac's window
would have shown it, the iPad shows it.

**Why this priority**: Answering a question you cannot see the reasons for is guessing.
This is what makes the escalation safe to answer and the device worth opening on its own —
and it is the part the person asked for in as many words. It is second only because a
notification that can be answered is worth having even before the reading is complete.

**Independent Test**: Put an agent on the Mac through a full piece of work — a prompt, a
command run, a file changed, a plan, a cost — then open the same agent on the iPad and
compare the two screens item by item. Anything on the Mac and not on the iPad is a failure
of this story.

**Acceptance Scenarios**:

1. **Given** the app is opened, **When** it draws, **Then** it shows the projects, and
   which of them has an agent waiting, as the Mac does.
2. **Given** a project, **When** it is opened, **Then** its agents are grouped "Needs
   input", "Working" and "Completed", in that order, empty groups omitted, with the same
   names and the same words the Mac uses.
3. **Given** an agent, **When** its conversation is opened, **Then** it shows the whole
   transcript — prompts, replies, tool calls, command output, diffs and the files a tool
   touched — laid out for the screen.
4. **Given** an agent with a plan, **When** the conversation is read, **Then** the plan is
   shown, and it changes as the agent changes it.
5. **Given** an agent that has spent money and used context, **When** the conversation is
   read, **Then** both are shown as reported and never estimated.
6. **Given** an agent that ended, **When** it is read, **Then** how it ended is said —
   finished, stopped, or the error — in the same words the Mac uses.
7. **Given** a project with archived agents, **When** they are asked for, **Then** they are
   shown, newest first, a batch at a time.
8. **Given** a conversation with a long history, **When** it is opened, **Then** the end of
   it is readable at once and the rest is fetched as the person scrolls back.
9. **Given** a tool call that changed a file, **When** the person opens that file from the
   transcript, **Then** they see its content and the change, read only, with no way offered
   to edit it.
10. **Given** an agent produced a document, **When** it is opened on the iPad, **Then** it is
    shown laid out for the screen, read only, as the Mac shows it.
11. **Given** the Mac's window changes something, **When** the iPad is open and connected,
    **Then** the iPad follows, without pulling to refresh.

---

### User Story 3 - Carrying on from the iPad (Priority: P3)

Having read what an agent did, the person types the next instruction and sends it. They
start a second agent in the same project. They stop one that has gone wrong, and archive
one that is done. The Mac does the work; the iPad said what to do.

**Why this priority**: Reading and answering already cover the interruption this whole
feature exists to remove. Being able to push the work forward is what makes the iPad
somewhere to sit for twenty minutes rather than ten seconds — worth having, and worth
having after the first two.

**Independent Test**: From the iPad, send a prompt to an existing agent, start a new agent
in an existing project, stop it, and archive another — confirming each on the Mac.

**Acceptance Scenarios**:

1. **Given** a conversation, **When** a prompt is sent from the iPad, **Then** the agent
   takes it exactly as if it had been typed at the Mac.
2. **Given** a project, **When** an agent is started from the iPad, **Then** it starts in
   that project's folder on the Mac, choosing from the runtimes the Mac has.
3. **Given** a running agent, **When** it is stopped from the iPad, **Then** it stops on the
   Mac.
4. **Given** a finished agent, **When** it is archived or unarchived from the iPad,
   **Then** the Mac agrees.
5. **Given** an action that cannot be delivered, **When** it is taken, **Then** it is
   refused at that moment rather than appearing to work.
6. **Given** an action taken on the iPad, **When** it lands, **Then** it has the same effect
   and is recorded the same way as the same action taken at the Mac.

---

### User Story 4 - Pairing an iPad, and taking it back (Priority: P4)

The person adds the iPad once, at the Mac, in under a minute, with no account to make and
nothing to type. Later, if the iPad is lost, they remove it at the Mac and it can see
nothing more.

**Why this priority**: Nothing works before it, so it is built early; but the value the
person feels is being asked on the train, not the minute of setup that made it possible. It
is last because the least of what they get is the setup.

**Independent Test**: Pair an iPad at the Mac, confirm it connects and is notified; revoke
it at the Mac and confirm it can read nothing afterwards, including with its app already
open.

**Acceptance Scenarios**:

1. **Given** a fresh iPad and the Mac app, **When** the person pairs them, **Then** it takes
   one short exchange begun at the Mac, with no account and no typed address.
2. **Given** a paired iPad, **When** it is opened days later on a network the Mac has never
   seen, **Then** it connects without pairing again.
3. **Given** the Mac, **When** paired devices are listed, **Then** each shows its name, when
   it was paired, when it last connected, and which notifications it wants.
4. **Given** a paired iPad, **When** it is revoked at the Mac, **Then** it loses access
   within seconds even if its app is open, and holds nothing readable afterwards.
5. **Given** an unpaired device, **When** it tries to connect, **Then** it is refused and
   shown how to pair, rather than failing silently.

---

### Edge Cases

- **The Mac is asleep, off, or off the network.** The iPad says so plainly, with when it
  last heard from it, and marks what it is showing as stale and read-only. An action that
  cannot be delivered is refused at the moment it is taken, never silently swallowed.
- **No window is open on the Mac.** The daemon holds the agents whether the window is there
  or not, so the iPad reaches them anyway, and the daemon does not exit while a paired
  device could still be asked to answer something.
- **The notification is answered while the Mac is unreachable.** The answer is either
  delivered once or not at all, and the person is told which. It is never shown as accepted
  and then quietly lost.
- **The same question reaches the Mac's window and the iPad at once.** The first answer
  wins; the other is told it was answered and by which device; no second answer is applied.
- **The question times out, or the agent is stopped, while the notification is still on the
  lock screen.** Answering it then says what became of it rather than acting on something
  that has gone.
- **The notification cannot be read.** If the iPad cannot turn the notification into words —
  for any reason — it still shows something true and generic that lands in the right place
  when opened. Never nothing, and never wrong.
- **A question that cannot be answered from a banner**: a form, or a permission whose whole
  point is a diff that must be read. The notification says there is something to look at and
  opens onto it, rather than offering a yes the person cannot justify.
- **A long conversation on a mobile connection.** The end of it opens quickly and the rest
  arrives as it is scrolled back to; the whole history is never fetched at once.
- **The Mac's folder for a project is gone.** As on the Mac: the project is marked missing,
  its agents stay readable, and starting a new agent in it is refused with a sentence saying
  why.
- **The iPad is lost.** Revoking at the Mac is enough. Nothing on it is readable without the
  device unlocked and nothing it kept can be used to reconnect.
- **An iPhone is paired anyway.** The app installs and runs on an iPhone throughout —
  nothing here excludes it — but it is not what this feature carries to done, and phone
  layout problems are recorded rather than fixed here.
- **Dynamic Type at its largest, and VoiceOver.** A permission the person cannot read in
  full is one they cannot answer; nothing about a question may be truncated away.

## Requirements *(mandatory)*

Feature 005 remains the design of record for how the iPad reaches the Mac — the two links,
the sealing, the pairing exchange, and the rule that nothing in the middle can read
anything. Its requirements are inherited whole and are not restated here except where this
feature sharpens or narrows them.

### Functional Requirements

#### Being asked

- **FR-001**: The system MUST notify a paired iPad whenever an agent needs the person: a
  permission request, or a form awaiting an answer.
- **FR-002**: A notification MUST name the project, the agent, and what is being asked, in
  enough detail to decide whether it is worth acting on.
- **FR-003**: The system MUST also notify when an agent finishes and when an agent stops on
  an error, and each of those two kinds MUST be turnable off independently, per device,
  without affecting FR-001.
- **FR-004**: The system MUST NOT notify about a question that has already been answered.
- **FR-005**: Opening a notification MUST land on the agent it names, showing whatever that
  agent's state is by then — including that the question is gone.
- **FR-006**: Notification content MUST NOT be readable by any service that carries it.
- **FR-007**: When a notification cannot be rendered into its real words, the system MUST
  still deliver a truthful generic notification that lands in the right place, rather than
  delivering nothing.

#### Answering

- **FR-008**: Users MUST be able to answer a permission request directly from the
  notification, without opening the app and without unlocking past the lock screen where the
  platform allows it.
- **FR-009**: The choices offered on the notification MUST be the Mac's choices, in the
  Mac's words. Where the platform cannot carry all of them, the notification MUST offer the
  ones it can and MUST make opening the full question the obvious alternative — it MUST NOT
  silently drop a choice.
- **FR-010**: When a question cannot be decided without seeing more — a diff, a file, a form
  — the notification MUST say so and MUST open onto the question in full rather than
  inviting a blind answer.
- **FR-011**: Users MUST be able to answer a permission request and a form from inside the
  app, with the same choices the Mac offers and no fewer, and with what is being asked shown
  in full.
- **FR-012**: The system MUST resolve each question exactly once however many places answer
  it, MUST tell the others it was already answered and by which device, and MUST NOT apply a
  second answer.
- **FR-013**: An answer MUST be delivered exactly once or not at all across a dropped
  connection, and the person MUST be told which.

#### What the iPad shows

- **FR-014**: The iPad MUST show the projects, marking which have an agent needing the
  person, as the Mac does.
- **FR-015**: The iPad MUST show a project's agents grouped "Needs input", "Working" and
  "Completed", in that order, empty groups omitted, using the same grouping the Mac uses.
- **FR-016**: The iPad MUST show an agent's full transcript: prompts, replies, tool calls,
  command output, diffs, and the files a tool call touched.
- **FR-017**: The iPad MUST show an agent's plan, and MUST keep it current as the agent
  changes it.
- **FR-018**: The iPad MUST show an agent's cost and its context usage, as reported and
  never estimated.
- **FR-019**: The iPad MUST say how an ended agent ended — finished, stopped, or the error —
  in the same words the Mac uses.
- **FR-020**: The iPad MUST show a project's archived agents on request, newest first, in
  batches.
- **FR-020a**: The iPad MUST be able to show the content of a file a tool call touched, read
  only, as the Mac's inspector does — the text as it stands, and the change if the tool made
  one. Editing it, or opening a file the agent never touched, stays at the Mac.
- **FR-020b**: The iPad MUST show a document an agent produced, read only, laid out for the
  screen as feature 007 lays it out on the Mac. Read only means read only: no editing, and no
  running anything the document describes.
- **FR-021**: The iPad MUST show anything else the Mac's window shows about an agent or a
  project that is a fact about the work rather than a fact about the Mac. Where something the
  Mac shows is deliberately not shown on the iPad, this spec MUST name it in *Out of scope*;
  silence is not a decision.
- **FR-022**: The iPad MUST use the same words as the Mac for the same things — group names,
  state names, action names — so that the two cannot be read as describing different things.
- **FR-023**: The iPad MUST reflect a change made on the Mac within the times feature 005
  promises, while it is open and connected, without the person refreshing.
- **FR-024**: The iPad MUST fetch transcript on demand rather than the whole history at once,
  so a long conversation opens quickly on a mobile connection.

#### What the iPad can do

- **FR-025**: Users MUST be able to send a prompt to an existing agent from the iPad.
- **FR-026**: Users MUST be able to start an agent in an existing project from the iPad,
  choosing from the runtimes the Mac has.
- **FR-027**: Users MUST be able to stop a running agent, and to archive and unarchive an
  agent, from the iPad.
- **FR-028**: The system MUST refuse an action it cannot deliver at the moment it is taken,
  rather than appearing to accept it.
- **FR-029**: An action taken on the iPad MUST have the same effect as the same action at the
  Mac, and MUST be recorded the same way.

#### Where the work stays

- **FR-030**: No agent may run on the iPad. The daemon on the Mac remains the only thing that
  runs work and the only writer of any record.
- **FR-031**: The iPad MUST NOT keep agent content, transcripts or secrets anywhere a revoked
  or lost device could still read them, and MUST require the device's own unlock before
  showing any agent content.
- **FR-032**: The Mac MUST remain fully usable with no device paired, and MUST NOT require any
  of this to be set up.

#### The iPad first, the iPhone next

- **FR-033**: The app MUST continue to build, install and run on an iPhone throughout this
  feature. Nothing here may be built in a way that has to be undone to finish the iPhone.
- **FR-034**: Every screen this feature delivers MUST be judged on real iPad hardware, not only
  in a simulator, before it is called done.
- **FR-035**: Where a screen is right on an iPad and wrong on an iPhone, the defect MUST be
  written down for the iPhone feature rather than fixed here or quietly tolerated.

#### Staying honest

- **FR-036**: The iPad MUST mark state as stale when it has lost touch with the Mac, MUST say
  when it last heard from it, and MUST NOT offer actions against stale state.
- **FR-037**: Everything shown MUST be reachable and readable with VoiceOver and at the largest
  ordinary text size; in particular, nothing about a question being asked may be truncated
  away.

### Key Entities

- **Escalation**: An agent's request for the person — a permission or a form — carried to the
  iPad as a notification and settled exactly once, wherever it is answered.
- **Paired device**: The Mac's record of a device it trusts: a name, when it was paired, when
  it last connected, which notifications it wants, and the means to verify it. Revocable.
  Unchanged from feature 005.
- **Project, Agent, Agent group**: Unchanged from feature 004. The iPad is another view of
  them, never a copy and never a second owner.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the iPad locked and the app not running, and the Mac on an unrelated
  network, a permission request on the Mac reaches the iPad as a notification within 5
  seconds.
- **SC-002**: A permission can be allowed or denied from the notification itself, with the app
  never opened, and the agent resumes on the Mac within 2 seconds of the answer.
- **SC-003**: The median time from an agent asking to the person answering, while away from the
  Mac, is under 5 minutes — measured against today's baseline of "discovered on return".
- **SC-004**: No question is ever answered twice, across 100 attempts to answer the same
  question from the notification and the Mac at once.
- **SC-005**: Screen-by-screen comparison of an agent on the Mac and the same agent on the iPad
  finds nothing about the work shown on one and missing from the other, except what this spec
  names in *Out of scope*.
- **SC-006**: Reaching any agent from the iPad takes at most two selections — the project, then
  the agent.
- **SC-007**: A conversation with an hour of transcript is readable within 2 seconds of opening
  on a mobile connection.
- **SC-008**: Setting up the iPad takes under 60 seconds, with no account, no typed address and
  no change to a router.
- **SC-009**: The iPad connects on the first try from at least three networks the Mac has never
  been on, including a mobile network.
- **SC-010**: A revoked iPad loses access within 10 seconds and can read nothing afterwards.
- **SC-011**: Traffic captured anywhere between the iPad and the Mac, including notification
  content, contains no readable prompt, transcript, file content, command or credential.
- **SC-012**: A person can complete a full working session from the iPad — read an agent,
  answer two questions, send a prompt, start an agent, stop one — without going to the Mac for
  anything this spec claims.
- **SC-013**: The app launches and every screen in this feature is reachable on an iPhone at the
  end of the feature, even where the layout is not yet right.
- **SC-014**: Every file a tool call touched in a conversation can be opened and read on the
  iPad, and no path through the app offers to change one.

## Assumptions

Decisions taken where the description did not say. Each is a candidate for
`/speckit-clarify`.

- **This feature delivers feature 005's unbuilt half, narrowed to one device.** 005 stays the
  design of record for reach, pairing, sealing, revocation and how a notification is carried;
  its research and contracts are reused rather than rewritten. What 013 changes is the scope
  and the order: iPad first, escalations first, the iPhone after. *Decided 2026-09-19:* **005
  stays open.** It is not superseded and it is not closed — 013 is its iPad slice, and a later
  feature is its iPhone slice. Anything 005 requires that this feature does not deliver is
  still owed; it is deferred to that later feature, not dropped. A requirement in 005 that
  reads as satisfied because the iPad satisfies it is not satisfied.
- **"Answer from the screen" means answering from the notification.** Not merely tapping
  through into the app. The banner carries the Mac's choices and settles the question where the
  person is looking, and opening the app in full is the fallback for questions too big for a
  banner (FR-010).
- **The headline is shown on a locked iPad, deliberately.** *Added 2026-09-19 from planning.*
  Feature 005's FR-012 says a remote must require the device's own unlock before showing any
  agent content, and a banner that can be read and answered names the project, the agent and
  the command. Those conflict, inherently. The resolution: the headline — and only the headline
  — is what is deliberately shown when locked. No transcript, no diff, no file content, no
  output. The platform's own "show previews" setting governs whether even that appears, rather
  than a second control of ours, and everything beyond allowing once requires the device to be
  unlocked first. **This is a privacy decision the person is entitled to overrule**, and it is
  written here rather than left in a research file for that reason.
- **The work and the daemon stay on the Mac.** Taken from the correction as stated. No agent
  runs on the iPad, nothing works offline, and the iPad becomes a second file system for
  nothing.
- **The layout stays the shape 005 specified** — projects, the project's agents, the
  conversation as a push, with the projects column beside the project on a wide iPad. Making the
  iPad a better-shaped app than the phone is not this feature; getting it working is.
- **Keyboard shortcuts, pointer support, multiple windows and drag-and-drop are out.** An
  earlier draft of this spec made them the feature. They are real and worth having, and they are
  a separate feature after this one, because none of them helps a person who cannot be told an
  agent is waiting.
- **The inspector splits in two, and the reading half comes to the iPad.** *Decided
  2026-09-19.* A file a tool touched and a document an agent produced are facts about the
  work, so they are shown, read only (FR-020a, FR-020b). The terminal and the browser are the
  Mac's window onto the Mac's own machine — a live shell on a tablet is a feature of its own,
  not a parity item — and they stay at the Mac. The line is not "which pane" but **what it
  is**: reading what the agent did comes across; driving the Mac does not.
- **Workflows (feature 008) are shown, not driven, on the iPad.** Where the Mac's project page
  lists a project's workflows, the iPad lists them too and says what they are doing; starting
  and confirming one stays at the Mac for now.
- **Making a project, archiving a project, renaming, and anything to do with runtime accounts
  or signing in stay at the Mac**, as 005 decided, for the same reason: they need the Mac's file
  system or the Mac's browser.
- **One person's devices, not a team.** Pairing is a person adding their own iPad. Sharing with
  somebody else is out of scope.
- **The Mac must be awake and on a network to be reached.** Waking a sleeping Mac is out of
  scope; the iPad says the Mac is unreachable and when it last was.
- **Nothing new is asked of the Mac's setup**: no login item, no installer, no port, no account
  beyond what feature 005 already assumes.

## Out of scope

Named here because FR-021 makes silence a defect rather than a decision.

- The driving half of the right-hand inspector (feature 002): the terminal and the browser.
  The reading half — a file a tool touched, a document the agent produced (feature 007) — is
  **in** scope, read only, under FR-020a and FR-020b.
- Editing a file from the iPad, or opening a file the agent never touched.
- Starting, confirming or cancelling a workflow (feature 008) from the iPad.
- Creating, archiving or renaming a project; changing runtime accounts; signing in to a runtime.
- Cost limits (feature 010) being set from the iPad; the iPad shows what is spent, and the Mac
  is where a limit is changed.
- Keyboard, pointer, multiple windows, drag-and-drop and any other iPad-specific ergonomics.
- The iPhone being finished. It keeps running; it is not judged, and its layout defects are
  recorded for a later feature.
- Running any agent, or any part of one, on the iPad.
