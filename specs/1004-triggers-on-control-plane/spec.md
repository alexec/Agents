# Feature Specification: Workflow triggers on the control plane

**Feature Branch**: `agents/spec-1004-triggers-on-control`

**Created**: 2026-10-14

**Status**: Draft

**Input**: Issue #1004, "Workflow triggers on the control plane, not on each host".

## Why this feature exists

Today each host decides for itself when its workflows run. Its own clock fires schedules, it
matches the events it raises, and it polls MCP servers such as `ci` for events like
`issue.opened`. So a host that is asleep or stopped decides nothing:

- A schedule that comes due while the host sleeps is not run. The workflow's page says it was
  missed (`missed_while_closed`).
- An issue opened while the host sleeps starts its workflow only when someone wakes the host.
- The Hosts row of a workspace with **Stop when idle** warns that its scheduled workflows don't
  run while it is stopped (#691, L8).

The control plane is already the part that stays up when a host is down. Workspace providers
run there "because the host is what is down", and it already **keeps** a prompt or a new agent
for a stopped workspace's host and starts the workspace (`docs/explanation/control-plane.md`,
"Starting the machines hosts run on"). This feature gives it the triggers too.

**The split:** the control plane decides **when** a workflow runs and **on which host**. The
host **runs** the agent, as it does now.

**Goals served** (`docs/explanation/direction.md`): "Agents land work on their own" (issue →
lane → pull request → merge with nobody watching) and "Hosts in the cloud". The control plane
still runs on the Mac for now, so until #61 puts it on an always-on machine, a sleeping Mac
still stops every workflow. #992 (keep the Mac awake on power) covers that time.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A schedule runs on a stopped workspace (Priority: P1)

Alex has a nightly review workflow pinned to the `devbox` host. Devbox is a workspace with
**Stop when idle**, so it is stopped at 03:00, when the workflow is due. The control plane sees
that the workflow is due, keeps the run, and starts devbox through its provider. When devbox
connects, the control plane sends it the run, and devbox starts the agent. In the morning, the
run is in the workflow's list as usual, and the workflow's page says it waited for devbox to
start.

**Why this priority**: This is the reason for the feature. Without it, a workspace that stops
when idle can't have a schedule.

**Independent Test**: With a scratch control plane, the Linux devbox linked to a workspace, and
a workflow due in two minutes pinned to devbox: stop the workspace, wait. The workspace starts,
the run starts on devbox, and its record says it waited for the host.

**Acceptance Scenarios**:

1. **Given** a scheduled workflow pinned to a stopped workspace's host, **When** it comes due,
   **Then** the control plane keeps the run, starts the workspace, and sends the run to the
   host when it connects.
2. **Given** a kept run, **When** the host connects, **Then** the run starts once, and only once,
   even if the host connects, drops and connects again.
3. **Given** a scheduled workflow on a host that is online, **When** it comes due, **Then** it
   runs at the same time as it does today (within the same 15 seconds).
4. **Given** a kept run, **When** Alex turns the workflow off or archives it before the host
   connects, **Then** the kept run is dropped and its record says why.

---

### User Story 2 - A new issue starts its workflow while the host is down (Priority: P1)

Alex has a workflow on `issue.opened` from the `ci` server that triages each new issue. The host
it runs on is stopped. Someone opens an issue. The control plane, which polls `ci`, sees it,
keeps a run for it, and starts the host as in User Story 1. The run is told its issue, as today.

**Why this priority**: The issue → lane → merge loop must not wait for someone to wake a
machine.

**Independent Test**: With `ci` polled by the scratch control plane and the workflow's host
stopped: open an issue on a test repository. The host starts and the run gets the issue's
details.

**Acceptance Scenarios**:

1. **Given** a workflow on a server's event, **When** the server reports the event and the
   workflow's host is down, **Then** the run is kept and the host started as in User Story 1.
2. **Given** a server's event, **When** two hosts have the same project, **Then** the event
   starts one run, not one per host (see FR-012).
3. **Given** the control plane restarts, **When** it polls again, **Then** it asks from where it
   stopped, and no event is lost or run twice.

---

### User Story 3 - See where a run stands (Priority: P2)

On the Mac, the Remote and the web page, a workflow's row and page show a run the control plane
keeps: **Waiting for devbox to start**, or **Waiting for Alex's MacBook to come back** for a
host that can't be started. Alex can drop a kept run with ×. The Hosts row loses its warning
that scheduled workflows don't run while it is stopped, because now they do.

**Why this priority**: A run that is kept and not seen looks the same as a trigger that never
matched.

**Independent Test**: Keep a run as in User Story 1 and look at the workflow on all three
clients: the same words, the same ×. Press × on one, and the others drop it.

**Acceptance Scenarios**:

1. **Given** a kept run, **When** Alex opens the workflow on any client, **Then** its row and
   page say which host it waits for and since when.
2. **Given** a kept run for a host that can't be started, **When** the keep time (FR-009) ends,
   **Then** the run is dropped and recorded as missed, naming the host.
3. **Given** a workspace with scheduled workflows and Stop when idle, **When** Alex looks at
   its Hosts row, **Then** there is no warning that its workflows don't run while it is
   stopped.

---

### User Story 4 - One run for a project on more than one host (Priority: P2)

Alex has the Agents project on the Mac and on devbox. A workflow with no `hosts:` line runs
today on **each** host that has the project, so a nightly check runs twice. With the control
plane deciding, it runs once, on one host.

**Why this priority**: Two runs of the same nightly check waste a turn and can race on the
same branch. This gets worse as hosts are added.

**Independent Test**: A project on two scratch hosts, a workflow due in two minutes, no
`hosts:`: one run, on the host FR-012 chooses.

**Acceptance Scenarios**:

1. **Given** a workflow with no `hosts:` on a project two hosts have, **When** it comes due,
   **Then** one run starts.
2. **Given** a workflow with `hosts:` naming two hosts, **When** it comes due, **Then** one run
   starts, on the first of them that is up; if none is up, the first that can be started is
   started.

---

### User Story 5 - Events a host raises still start workflows (Priority: P3)

`agent.finished`, `project.idle`, `branch.moved`, `dropbox.file_added` and the `mac.*` events
come from a host. The host still raises them. The control plane matches them against the
workflows and sends the run, usually to the same host.

**Why this priority**: These already work today, and they must keep working after the move. A
host raising them is up, so they gain least from it.

**Independent Test**: The workflow tests for these events pass with the control plane deciding.
A run is told its event as today.

**Acceptance Scenarios**:

1. **Given** a workflow on `agent.finished`, **When** an agent on the host finishes, **Then** the
   run starts as quickly as it does today.
2. **Given** the control plane is unreachable, **When** a host raises events, **Then** the host
   keeps them and the control plane matches them when it reconnects; each starts at most one
   run.
3. **Given** `agent: triggering` or `agent: standing`, **When** a run starts, **Then** it goes
   to the host that has that agent.

---

### User Story 6 - Older hosts keep working (Priority: P3)

A host on a version from before this feature still fires its own workflows. The control plane
does not fire for it, so nothing runs twice. Its workflow pages say that this host decides for
itself and that updating it lets its workflows run while it is down.

**Independent Test**: A scratch control plane with one new host and one old host: each
workflow runs once.

**Acceptance Scenarios**:

1. **Given** an old host, **When** its workflow comes due, **Then** it runs once, fired by the
   host.
2. **Given** a host is updated, **When** it connects, **Then** the control plane takes over its
   triggers, including held cooldowns and queues, without a run lost or run twice.

---

### Edge Cases

- **The control plane itself is down or asleep** (today, when the Mac sleeps). Schedules that
  come due in that time are recorded as missed when it is back, as today. Server events are
  caught up from the poll's cursor. Host events are kept by the host and caught up (User Story
  5).
- **A host that has the workflow file but has not approved it, or denied it.** The control plane
  never sends it a run. Approval stays the host's (FR-011).
- **The workflow file changes while the host is down.** The control plane uses the last copy the
  host sent. When the host connects with a newer copy, a kept run is checked again against it:
  turned off, archived, or no longer matching drops the run, with a record of why.
- **A provider fails to start the workspace.** The run stays kept, the workflow's page says the
  start failed and why, and the keep time still applies.
- **Many kept runs for one host** (a schedule every 30 minutes while a host is down all day).
  One workflow keeps at most one run per schedule and its queue (10) as today, not one per
  missed time.
- **A cooldown or queue** behaves as today, counted by the control plane.
- **Run now** is unchanged: it goes to a host now, and it is refused for a host that is down,
  as other requests are, unless the host can be started.
- **A control plane with more than one copy.** Only the copy that runs the providers fires
  workflows, so no trigger fires twice.

## Requirements *(mandatory)*

### Functional Requirements

**Deciding**

- **FR-001**: The control plane MUST decide when every workflow on an up-to-date host fires: on
  its schedule, on a server's event, and on an event a host raises. Hosts MUST NOT fire them
  themselves.
- **FR-002**: The control plane MUST keep, in its store, what it needs to decide for a host that
  is down: each host's workflows (triggers, `hosts:`, `enabled:`, `archived:`, `cooldown:`,
  `agent:`), whether the host approved or denied each one, held and queued triggers, and fire
  records.
- **FR-003**: A host MUST send its workflows and their approval state to the control plane when
  it connects and whenever one changes.
- **FR-004**: A schedule MUST fire within 15 seconds of its time when the control plane is up, as
  today.
- **FR-005**: The control plane MUST poll the MCP servers that workflow triggers name, with the
  pace, cursor and "events may have been missed" rules they have today.
- **FR-006**: A host MUST send the events it raises to the control plane, and keep them while
  the control plane is unreachable, so that each starts at most one run.

**Hosts that are down**

- **FR-007**: A fire for a host that is down MUST be kept by the control plane, as kept prompts
  are, and the host's workspace MUST be started when it has a provider.
- **FR-008**: A kept run MUST be sent to the host when it connects, and MUST start once only.
- **FR-009**: A kept run for a host that does not come back MUST be dropped after
  [NEEDS CLARIFICATION: how long a kept run waits for a host that can't be started — until the
  workflow's next due time, a fixed time such as 24 hours, or until the host comes back], and
  recorded as missed, naming the host.
- **FR-010**: Turning a workflow off, archiving it, or a newer copy of its file that no longer
  matches MUST drop its kept run, with a record that says why.
- **FR-011**: The control plane MUST send a run only to a host that has approved the workflow
  and not denied it. Approval and Deny stay on each host.

**Which host**

- **FR-012**: A workflow on a project more than one host has MUST start one run per fire, not
  one per host. With no `hosts:`, the host is
  [NEEDS CLARIFICATION: which host runs a workflow with no `hosts:` — the host whose copy of
  the file is newest, the first host listed for the project, or one Alex chooses on the
  workflow's page]. With `hosts:`, it is the first listed host that is up, else the first that
  can be started.
- **FR-013**: A run for `agent: standing` or `agent: triggering` MUST go to the host that has
  that agent.

**Server events**

- **FR-014**: MCP servers that workflow triggers name MUST run where the control plane can poll
  them while the hosts are down:
  [NEEDS CLARIFICATION: where they run — on the control plane's machine, with their sign-ins in
  its own folder as providers have; or on one host the control plane chooses, which must then
  be up].

**Clients**

- **FR-015**: The workflow's row and page MUST show a kept run, the host it waits for, since
  when, and a × to drop it, on the Mac, the Remote and the web page.
- **FR-016**: The Hosts row's warning that scheduled workflows don't run while a workspace is
  stopped MUST go for up-to-date hosts.
- **FR-017**: A workflow on an old host MUST say that its host decides for itself.

**Moving across**

- **FR-018**: A host from before this feature MUST keep firing its own workflows, and the
  control plane MUST NOT fire for it.
- **FR-019**: When a host first connects with this feature, its held cooldowns, queues and fire
  records MUST move to the control plane with none lost or run twice.
- **FR-020**: In a control plane with more than one copy, only one copy MUST fire workflows at a
  time.

### Key Entities

- **Workflow copy**: what the control plane knows of one workflow on one host: its triggers and
  settings, the file's version, and the host's approval. Sent by the host.
- **Kept run**: a fire waiting for its host: the workflow, the trigger and its event, the host,
  when it was kept, and why it waits (starting, can't be started).
- **Fire record**: what became of a fire (ran, held, queued, refused, missed, dropped), as the
  workflow's page shows today, now kept by the control plane.
- **Server subscription**: one MCP server event the control plane polls, with its cursor.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A scheduled workflow on a stopped workspace's host starts its run no later than
  the workspace's start time plus one minute after it comes due.
- **SC-002**: An issue opened while its workflow's host is stopped starts its run within one
  poll interval plus the workspace's start time.
- **SC-003**: Across 100 fires of a workflow on a project two hosts have, there are exactly 100
  runs.
- **SC-004**: A host stopped for 8 hours with a workflow every 30 minutes gives one kept run per
  schedule, not 16, and none missed while its workspace can be started.
- **SC-005**: Fires on an online host start as quickly as they do today: no event-triggered run
  later by more than 2 seconds.
- **SC-006**: The three clients show a kept run with the same words, and × on one drops it on
  all three within 2 seconds.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md` — add: the control plane decides when workflows run; kept
  runs; which copy fires.
- `docs/reference/workflows.md` — change: the schedule row ("a time missed while the Mac
  slept"), `hosts:` (one run, which host), a kept run on the workflow's page.
- `docs/reference/events.md` — change: where server events are polled; host events caught up
  after the control plane is back.
- `docs/how-to/start-workspaces-from-agents.md` — change: scheduled workflows now start a
  stopped workspace; the Hosts row warning is gone.
- `docs/explanation/direction.md` — change: note that workflows run while hosts are down, and
  without a Mac awake once #61 lands.

## Assumptions

- Every setup has a control plane since 058 (Agents Host runs it on the Mac). A host with no
  control plane is out of scope.
- The control plane stays on the Mac until #61. Until then a sleeping Mac stops the control
  plane, and its missed schedules are recorded as missed, as today.
- A Mac host can't be started by a provider. A run kept for a Mac waits for it to wake, up to
  the keep time (FR-009).
- The workflow file stays in the project on the host's disk. Editing, approving, the Enabled
  switch and the page's menus don't change.
- The limits (three waiting for approval per project, ten running) stay counted per host.
- The run itself, its prompt, its agent, `when-done:` and its session don't change.
- `missed_while_closed` stays, for time the control plane itself was down, and for a kept run
  whose keep time ended.
