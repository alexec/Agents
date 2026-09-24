# Feature Specification: What Survives a Restart

**Feature Branch**: `025-surviving-a-restart`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "State that should survive a restart but does not: attention deliveries and the moment a need was first raised, so a restarting daemon stops re-alerting the phone for a need it already delivered and can withdraw a banner for a question that died with it; workflow runs in flight, so a workflowCompleted chain still fires and the chain-depth ceiling survives a restart; a transcript line when a permission or form dies unanswered with its process, its stop, or the daemon; and the composer's unsent prompt text, attachments and start-form draft kept across an app relaunch."

## Why this feature exists

The daemon restarts more often than anything else in this app. Every build restarts it.
Every update restarts it. A logout, a crash, a Mac that rebooted overnight — all of them
restart it, and the whole design says that should cost the person nothing they can see.
An agent that was working is picked back up. Its record, its transcript, its cost, its
queue, its plans and its suggestions are all still there, because each of them was written
down at the moment it became true.

A handful of things were not, and they were not because when each was written the thing it
described was tied to a process that died anyway. That reasoning is right for most of
them: where the person is, what a live runtime last quoted, what a page was edited to —
none of that outlives the thing it is about, and writing it down could only mislead the
next daemon.

But four of them are about the person, not about a process, and losing those is something
the person can see:

- **The phone is buzzed twice for the same thing.** A finished agent whose report says it
  is stuck is a need that survives the restart perfectly well — it is read straight off
  the record. What does not survive is the fact that it was already delivered, and already
  alerted. So the restart alerts it again, on a Mac that builds this app ten times a day.
  The moment the need was first raised is lost with it, which restarts the pause the
  person gets to look at their own screen before anything else is told.

- **A banner stays on a phone for a question that no longer exists.** When a question does
  die with its runtime, the next daemon does not know a phone was ever shown it, so it
  never takes it down. The phone clears it when it next connects to the daemon directly,
  and until then it is showing a question nobody can answer.

- **A workflow chain stops half way.** A run in flight is the only part of the workflow
  bookkeeping held in memory. If the daemon goes while one is running, the agent comes
  back and finishes, but nothing set to run when that workflow completes ever hears about
  it, and the depth that stops a chain looping resets to zero.

- **What you had typed is gone.** Words sent to an agent are on the record within
  milliseconds. Words half-typed are not written down anywhere, so closing the window on a
  paragraph you were composing loses it, along with anything dragged in beside it and every
  choice made on a start form that had not been started yet.

None of these is a new capability. Each is a fact the app already has, at the moment it
already has it, being written down so the next daemon knows it too.

The discipline is knowing where to stop. This feature does not make live things durable.
It does not try to keep a question answerable after the runtime that asked it has gone, it
does not resume a turn, and it does not restore a shell. Those things die with their
processes and should. What is written down here is only what remains true after the
process is gone.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - You are not told twice about the same thing (Priority: P1)

An agent finishes at eleven o'clock saying it is stuck, and your phone shows it. You are
out, so you leave it. At noon the app is updated and the daemon restarts underneath it.
Your phone does not buzz again: the thing it is telling you about has not changed, and
being told about it a second time would teach you that the app's notifications mean
nothing in particular.

**Why this priority**: It is the one that reaches the person's pocket, and it is the one
that fires most often — the daemon restarts on every build of this app. A notification
that repeats itself for no reason is worse than no notification, because it is what makes
somebody turn them off.

**Independent Test**: Raise a need that outlives a restart — an agent that finishes with an
outcome saying it needs a person — let it be delivered and alerted, restart the daemon, and
confirm no fresh alert is raised and the need is still shown in the same place.

**Acceptance Scenarios**:

1. **Given** an outstanding need that has been delivered to a surface and alerted,
   **When** the daemon restarts and the need is still outstanding, **Then** it is still
   shown on the same surface and the person is not alerted again.
2. **Given** that same need, **When** the daemon restarts, **Then** the time it was first
   raised is the original time, not the time of the restart.
3. **Given** a need first raised four seconds before the daemon restarted, and a person
   at the Mac, **When** the daemon comes back, **Then** the pause that lets them look for
   themselves is not started again from the beginning.
4. **Given** an outstanding need that had been delivered to a phone, **When** the daemon
   restarts and the person has since come to the Mac, **Then** it moves to the Mac exactly
   as it would have without the restart.
5. **Given** a need that was delivered and alerted long enough ago that the app would
   ordinarily alert again, **When** the daemon restarts, **Then** the ordinary re-alert
   rule applies — the restart neither suppresses it nor brings it forward.

---

### User Story 2 - A question that is gone stops asking (Priority: P1)

An agent asks whether it may delete a file, and the question reaches your phone. The Mac
reboots. The agent's runtime died with it, so the question cannot be answered by anybody,
ever. The banner on your phone goes away on its own, without you having to open the app to
find out it means nothing.

**Why this priority**: The same weight as the story above and its exact mirror. One is
being told a thing twice; this is being told a thing that is no longer true. Both end in
the same place — a person who stops believing what the app tells them.

**Independent Test**: Hold a question, let it be delivered to a device, restart the daemon
without that device connected, and confirm a withdrawal is sent for it.

**Acceptance Scenarios**:

1. **Given** a need that had been delivered to a device, **When** the daemon restarts and
   the need no longer exists, **Then** a withdrawal for it is sent to that device.
2. **Given** that withdrawal, **When** the device is not reachable at the moment the
   daemon comes back, **Then** it is still delivered when the device is next reachable.
3. **Given** a need that had been delivered to the Mac rather than to a device, **When**
   the daemon restarts and the need no longer exists, **Then** the Mac's own notification
   for it is taken down.
4. **Given** a device that reconnects and finds a notification for a need the daemon does
   not have, **Then** it still clears it — the withdrawal is the first line of defence
   and this remains the second.

---

### User Story 3 - A restart does not break a chain of workflows (Priority: P2)

You have one workflow that runs the tests each morning and another set to run when the
first one completes. The daemon restarts while the first is still working. The agent comes
back, finishes, and the second workflow runs — the same as it would have on any other
morning.

**Why this priority**: Below the two above because it is rarer: it needs a restart inside
the window of a run. Above everything below it because the failure is silent. Nothing is
shown, nothing is logged for the person, and the only evidence is a workflow that did not
run — which is indistinguishable from one nobody was watching.

**Independent Test**: Start a workflow run, restart the daemon while its agent is still
working, let the agent finish, and confirm a workflow chained on its completion fires.

**Acceptance Scenarios**:

1. **Given** a workflow run in flight, **When** the daemon restarts and the run's agent
   then finishes, **Then** every workflow waiting on that workflow's completion fires.
2. **Given** a chain three deep, **When** the daemon restarts part-way down it, **Then**
   the depth carries on from where it was rather than starting again at zero, and the
   ceiling that stops a runaway chain still applies.
3. **Given** a workflow run in flight, **When** the daemon restarts, **Then** the project
   page shows that workflow as running, and stops doing so when the run is over.
4. **Given** a run in flight whose agent is gone by the time the daemon comes back —
   archived, or deleted — **Then** the run is released rather than held open forever, and
   anything chained on it is not fired, because the run did not complete.
5. **Given** a workflow whose run was in flight across a restart, **When** it is triggered
   again before that run finishes, **Then** it is refused as a run already in flight, the
   same as it would be without the restart.

---

### User Story 4 - The conversation says the question was never answered (Priority: P3)

You scroll back through an agent's conversation and find where it asked whether it could
run the tests. Underneath, in the app's own voice, is a line saying the question went
unanswered because the agent stopped. You do not have to work that out from the absence of
a reply.

**Why this priority**: Nothing is lost without it — the question really is gone and the
agent really did stop, and both of those are already written down. What is missing is the
sentence that joins them. It is the cheapest thing in this feature and the one a person
meets months later, reading back.

**Independent Test**: Hold a question, end its agent three different ways — the runtime
exits, the person stops it, the daemon restarts — and confirm each conversation carries a
line saying the question was never answered.

**Acceptance Scenarios**:

1. **Given** an agent with a question outstanding, **When** its runtime exits, **Then** the
   conversation records that the question went unanswered, before the line recording the
   ending.
2. **Given** an agent with a question outstanding, **When** the person stops it, **Then**
   the conversation records the same thing.
3. **Given** an agent with a question outstanding, **When** the daemon restarts, **Then**
   the conversation records the same thing.
4. **Given** an agent with a form outstanding rather than a permission, **Then** all three
   endings record it in the same way.
5. **Given** a question that was answered, **Then** nothing extra is recorded — the answer
   is already the line that closes it.

---

### User Story 5 - What you had half-typed is still there (Priority: P3)

You are three paragraphs into explaining a job, with two files dragged into the bar, when
you quit the app by accident. You open it again and the paragraphs and the files are where
you left them.

**Why this priority**: The smallest loss and the most annoying one. It is last because
nothing is at stake beyond retyping, and because it is the only part of this feature that
belongs to the window rather than to the daemon.

**Independent Test**: Type into the prompt bar without sending, attach a file, quit the
app, reopen it, and confirm both are still there against the same conversation.

**Acceptance Scenarios**:

1. **Given** unsent text in the prompt bar for a conversation, **When** the app is quit and
   reopened, **Then** the text is still there against that conversation.
2. **Given** attachments and file mentions staged beside that text, **When** the app is
   quit and reopened, **Then** they are still staged.
3. **Given** a half-filled start form — a folder chosen, a runtime chosen, extra folders
   and servers added, options set — **When** the app is quit and reopened, **Then** those
   choices are still made.
4. **Given** unsent text, **When** it is sent, **Then** nothing is kept — a draft exists
   only until it becomes a prompt.
5. **Given** unsent text for a conversation that has since been archived or deleted,
   **When** the app is reopened, **Then** the draft is discarded rather than reappearing
   against nothing.
6. **Given** two windows open on the same conversation, **Then** both show the same draft,
   as they already show the same selection.

---

### Edge Cases

- **A need is met while the daemon is down.** An agent whose report asked for a person is
  archived by the time the daemon returns. The need is gone, and the withdrawal for it
  still has to go: the person's phone does not know the agent was archived.
- **The same need is raised again later.** A question asked, lost with a restart, and asked
  again is a new need with a new first-raised time — a stored delivery must not make a
  fresh question look like one already shown.
- **What was written down names something that has gone.** A stored delivery for a device
  that has since been unpaired, or a stored run for a workflow whose file has been deleted,
  is discarded rather than acted on.
- **The stored file cannot be read.** Every one of these is bookkeeping, not work. An
  unreadable file means starting that piece of bookkeeping again — never refusing to start,
  and never losing an agent.
- **The daemon is killed rather than asked to stop.** Nothing here may depend on a tidy
  shutdown. Each fact is written at the moment it becomes true, in the same way the agent
  record and the transcript already are.
- **A restart between a decision and its being written.** A daemon that dies in that gap
  behaves exactly as today's does. This feature narrows the window; it cannot close it.
- **The clock moved.** A first-raised time read back after the machine's clock changed must
  not produce a pause that never elapses or an alert that fires immediately.
- **Drafts accumulate.** A person who starts prompts in twenty conversations and sends none
  should not carry twenty drafts forever; stale ones are let go.

## Requirements *(mandatory)*

### Functional Requirements

**What the app remembers about telling you something**

- **FR-001**: The app MUST remember, across a restart, which outstanding needs it has
  delivered, where each was delivered, when the person was last alerted about each, and how
  many times.
- **FR-002**: The app MUST remember, across a restart, the moment each outstanding need was
  first raised, and MUST NOT move it.
- **FR-003**: On restarting, the app MUST NOT alert the person afresh about a need that was
  already delivered and alerted, unless the ordinary rules for alerting again would have
  applied anyway.
- **FR-004**: On restarting, the app MUST send a withdrawal for every need it had delivered
  that no longer exists, to the surface it was delivered to.
- **FR-005**: A withdrawal MUST reach a device that was not reachable at the moment it was
  decided, once that device is next reachable.
- **FR-006**: The app MUST discard remembered deliveries that name a surface it no longer
  knows, without failing.
- **FR-007**: What the app remembers about delivery MUST NOT include what the need is
  about. It is a note that something was shown somewhere, not a second copy of the
  question.

**What the app remembers about a workflow that is running**

- **FR-008**: The app MUST remember, across a restart, every workflow run in flight: which
  workflow, which agent, how deep in a chain, and when it started.
- **FR-009**: When an agent belonging to a remembered run finishes, the app MUST fire every
  workflow waiting on that workflow's completion, exactly as it would have without the
  restart.
- **FR-010**: The app MUST count chain depth from the remembered run, so that the ceiling
  on a chain still applies across a restart.
- **FR-011**: The app MUST show a remembered run as running until it is over.
- **FR-012**: The app MUST release a remembered run whose agent no longer exists, or is
  archived, without firing anything chained on its completion.
- **FR-013**: A remembered run MUST refuse a second fire of the same workflow while it is
  still in flight, as an unremembered one does.

**What the conversation says about a question nobody answered**

- **FR-014**: When a permission request or a form is outstanding and its agent's runtime
  exits, the person stops it, or the daemon restarts, the app MUST record in that
  conversation that the question went unanswered.
- **FR-015**: That line MUST be recorded before the line recording the ending, so the
  conversation reads in the order things happened.
- **FR-016**: That line MUST NOT be recorded for a question that was answered, declined,
  cancelled or withdrawn — each of those already closes itself.
- **FR-017**: The line MUST be in the app's own voice and MUST NOT be attributed to the
  person or to the agent.

**What the window remembers about what you were typing**

- **FR-018**: The app MUST keep unsent prompt text across a relaunch, against the
  conversation it was typed for.
- **FR-019**: The app MUST keep attachments and file mentions staged beside that text.
- **FR-020**: The app MUST keep the choices made on a start form that has not been started
  — the folder, the runtime, additional folders, attached servers, and options chosen.
- **FR-021**: The app MUST discard a draft the moment its text is sent.
- **FR-022**: The app MUST discard a draft whose conversation no longer exists or has been
  archived.
- **FR-023**: A draft MUST belong to the conversation it was typed for, and be the same
  draft in every window of the app — the rule the selected project and the sidebar
  already follow. *(Amended during planning, 2026-09-24: this asked for a draft per
  window, which no other part of the window's state does. The app holds one model across
  every window; a draft that behaved differently would be the odd one out, and the
  machinery to make it so would exist for this field alone.)*
- **FR-024**: Drafts MUST be kept where the window keeps what it knows, not where the
  daemon keeps what is true about the work. A draft is not the work.

**Across all of it**

- **FR-025**: Every fact named here MUST be written at the moment it becomes true, so that
  a daemon killed without warning leaves it behind.
- **FR-026**: Anything written here that cannot be read back MUST be treated as absent, and
  MUST NOT prevent the app starting or cost the person an agent, a transcript or a project.
- **FR-027**: Nothing here may make a dead question answerable, resume a turn, or restore a
  shell. What is remembered is only what remains true once the process is gone.

### Key Entities

- **Delivery note**: That a particular outstanding need was shown on a particular surface,
  when the person was last alerted about it, and how many times. Holds no content.
- **First-raised time**: When the app first saw an outstanding need. One per need, and it
  never moves while the need is outstanding.
- **Run in flight**: A workflow that is running: which workflow, in which project, which
  agent it is using, how deep in a chain it sits, and when it began.
- **Unanswered-question line**: A line in a conversation saying a question ended without an
  answer, and why.
- **Draft**: What a window is holding for a conversation that has not been sent — text,
  attachments, mentions — and, for a conversation that does not exist yet, the choices made
  on its start form.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Restarting the daemon while a need is outstanding produces zero fresh alerts
  for that need, across ten consecutive restarts.
- **SC-002**: A need shown on a phone and then met while the daemon is down is cleared from
  that phone without the person opening the app.
- **SC-003**: A workflow chained on another's completion fires in 100% of runs interrupted
  by a restart, matching its rate in runs that were not.
- **SC-004**: The depth ceiling stops a looping chain at the same depth whether or not the
  daemon restarted part-way through it.
- **SC-005**: Every conversation whose question ended unanswered carries a line saying so,
  for all three ways of ending, and no conversation whose question was answered carries one.
- **SC-006**: Unsent text, attachments and start-form choices are intact after quitting and
  reopening the app, with no keystroke lost.
- **SC-007**: A person can tell from the transcript alone, months later, whether a question
  was answered, and no new question about what happened is left to the log.
- **SC-008**: None of the above is achieved at the cost of an agent, a transcript or a
  project being lost when the file holding it cannot be read.

## Assumptions

- The three existing bookkeeping files — projects, workflows and devices — establish the
  pattern for anything else the daemon has to remember about itself, and this feature
  follows it rather than introducing a different one.
- A need that the daemon can no longer produce is met, not pending. The daemon does not try
  to work out whether a question it has lost might come back.
- The delivery note is kept only while its need is outstanding. Nothing here becomes a
  history of what the person was told.
- Drafts belong to the window, not to the daemon. The daemon is not told about them, and a
  phone and a Mac do not share one.
- A draft is discarded rather than migrated if the app cannot read what it wrote last time.
- The transcript line for an unanswered question is a note from the app, of the kind the
  conversation already carries for a runtime starting or a daemon stopping.
- The window's existing rules about which conversation is selected and which project is
  shown are unchanged; a restored draft appears where it was typed, and does not select
  anything by itself.
