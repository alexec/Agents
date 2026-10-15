# Feature Specification: Start a stopped workspace for its next scheduled workflow

**Feature Branch**: `agents/spec-1004-triggers-on-control`

**Created**: 2026-10-14

**Status**: Draft

**Input**: Issue #1004. Alex decided (2026-10-14): **scheduling stays on the hosts.** The
control plane only gives a stopped workspace a **wake-up call** before its next scheduled
workflow.

## Why this feature exists

Each host decides for itself when its workflows run: its own clock fires schedules, it matches
the events it raises, and it polls MCP servers such as `ci`. This stays as it is.

A workspace host with **Stop when idle** (#691) is stopped by the control plane when it is idle,
and a stopped host runs nothing. Its scheduled workflows don't run. Its Hosts row warns about
this (#691, L8). So today, a workspace can stop when idle or have a schedule, but not both.

The control plane already stops these workspaces and starts them again through their
providers. It already hears from each host, on the host's own channel, whether the host is
idle. This feature adds one thing to that message: **when the host's next scheduled workflow
is due.** The control plane then starts the stopped workspace a little before that time. The
host connects, its own clock fires the workflow as usual, and when it is idle again, the
control plane stops it again.

**Goal served** (`docs/explanation/direction.md`): "Hosts in the cloud" (workspace providers
start and stop the machines hosts run on), and "Agents land work on their own", for scheduled
work.

**Not in this feature:**

- Event and server-event triggers (`issue.opened`, `agent.finished`). A stopped host still hears
  them only when it starts again.
- A Mac host. No provider can start a Mac. #992 (keep the Mac awake on power) covers that.
- Moving any trigger to the control plane. That was the first draft of #1004, and Alex did not
  choose it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A stopped workspace starts for its schedule (Priority: P1)

Alex has a nightly review workflow on the `devbox` host, due at 03:00. Devbox is a workspace
with **Stop when idle**, and it stopped at 23:40. At about 02:55, the control plane starts
devbox through its provider. Devbox connects, and at 03:00 its own clock fires the workflow.
The run finishes. Thirty minutes later, devbox is idle, and the control plane stops it again.

**Why this priority**: This is the whole feature. It lets a workspace both save money and run a
schedule.

**Independent Test**: A scratch control plane, the Linux devbox linked to a workspace with a
1-minute idle stop, and a workflow due in 10 minutes. Let devbox stop. It starts again before
the due time, the workflow runs at its time, and devbox stops again after a minute idle.

**Acceptance Scenarios**:

1. **Given** a stopped workspace whose host has a scheduled workflow, **When** the start time
   for it comes (FR-004), **Then** the control plane starts the workspace through its provider.
2. **Given** the host connects before the due time, **When** the due time comes, **Then** the
   host fires the workflow itself, as it does today.
3. **Given** the run is done and the host is idle, **When** its idle time passes, **Then** the
   control plane stops the workspace, as today.
4. **Given** a host whose next scheduled workflow is due within its idle time, **When** it would
   be stopped as idle, **Then** it is not stopped. It stays up for the run.

---

### User Story 2 - See the next wake-up call (Priority: P2)

On the Mac, the Remote and the web page, a stopped workspace's Hosts row says when it will
start, and for which workflow: **Starts at 02:55 for Nightly review**. The old warning that
scheduled workflows don't run while it is stopped goes.

**Why this priority**: A machine that starts by itself, and costs money while it runs, must say
so where Alex looks at it.

**Independent Test**: Stop the scratch workspace with a workflow due later. All three clients
show the same line on its Hosts row.

**Acceptance Scenarios**:

1. **Given** a stopped workspace with a next wake-up call, **When** Alex looks at its Hosts row
   on any client, **Then** the row says when it starts and for which workflow.
2. **Given** a stopped workspace with no scheduled workflow, **When** Alex looks at its row,
   **Then** it says nothing about a wake-up call.
3. **Given** a host with scheduled workflows and Stop when idle, **When** Alex looks at its row,
   **Then** there is no warning that its workflows don't run while it is stopped.

---

### User Story 3 - Turn wake-up calls off for one host (Priority: P3)

Alex wants a workspace to stay stopped (for example, over a holiday) even though it has a
schedule. A **Start for scheduled workflows** switch on the host's row, on by default, turns off
its wake-up calls. Its schedules are then missed while it is stopped, as today, and the row
says so.

**Independent Test**: Turn the switch off, stop the workspace, let a due time pass. It does not
start, and the workflow's page records the time as missed when the host is next up.

**Acceptance Scenarios**:

1. **Given** the switch is off, **When** a due time comes, **Then** the workspace is not
   started.
2. **Given** Alex presses **Stop** on a host's row, **When** it stops, **Then** the wake-up calls
   still apply, unless the switch is off. The confirmation says when it will start next.

---

### Edge Cases

- **The host starts late** (the provider is slow, or the start fails). A workflow whose time
  passed before the host was up is recorded as missed, as today. The control plane learns how
  long the workspace took to start, and starts it earlier next time (FR-004). A failed start is
  shown on the Hosts row, as today.
- **The workflow file changes while the host is stopped** (a push to the repository). The
  control plane only knows the due times the host last sent. A new workflow is not seen until
  the host is next up. A removed or turned-off one may cause one start for nothing; the host
  then goes idle and stops again.
- **Several workflows due close together.** The host stays up through them all if each is due
  within its idle time of the last (User Story 1, scenario 4). Otherwise it is started for each.
- **A workflow pinned to another host** (`hosts:`). Only the hosts that run it send its due
  time.
- **A workflow that is off, archived, waiting for approval or denied** sends no due time.
- **A schedule every 30 minutes and an idle time of 30 minutes or more.** The host never stops.
  The row says that it stays up for its schedule.
- **The control plane is down at the start time** (it runs on the Mac, and the Mac sleeps).
  Nothing starts the workspace, and the schedule is missed, as today. #61 removes this.
- **The control plane runs as more than one copy.** Only the copy that runs providers makes
  wake-up calls, as it is the only one that starts and stops workspaces now.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each host MUST keep deciding when its workflows fire. Nothing in this feature MUST
  change when or how a host fires a workflow.
- **FR-002**: With the idle status it sends now, a host MUST send the control plane the time of
  its next scheduled workflow (and the workflow's name), counting only workflows that run on
  it, are approved, are on and are not archived. It MUST send it again when that time changes.
- **FR-003**: The control plane MUST keep the last next-due time of each linked host while the
  host is stopped.
- **FR-004**: The control plane MUST start a stopped workspace early enough for the host to
  connect before the due time: by the workspace's last measured start time plus 2 minutes, or
  5 minutes when no start has been measured.
- **FR-005**: The control plane MUST NOT stop a workspace as idle when its next due time is
  within its idle time.
- **FR-006**: A wake-up call MUST start a workspace once per due time, however often the control
  plane restarts or the host reconnects.
- **FR-007**: The Hosts row of a stopped workspace MUST say when it starts next and for which
  workflow, on the Mac, the Remote and the web page.
- **FR-008**: The Hosts row warning that scheduled workflows don't run while a workspace is
  stopped MUST go when wake-up calls are on.
- **FR-009**: Each linked host MUST have a **Start for scheduled workflows** switch, on by
  default. With it off, the control plane MUST NOT start the workspace for a schedule, and the
  row MUST say that its scheduled workflows don't run while it is stopped.
- **FR-010**: Stopping a workspace by hand MUST say, in its confirmation, when it will start
  next, when a wake-up call is set.
- **FR-011**: A host from before this feature sends no due time. The control plane MUST make no
  wake-up calls for it, and its row MUST keep the old warning.

### Key Entities

- **Next due time**: per host, the time of its next scheduled workflow and that workflow's name.
  Sent by the host, kept by the control plane.
- **Wake-up call**: per stopped workspace, the time the control plane will start it, worked
  out from the next due time and the measured start time.
- **Measured start time**: per workspace, how long its last start took from the request to the
  host connecting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A scheduled workflow on a workspace stopped as idle runs at its due time, within
  the same 15 seconds as on a host that never stopped, in 19 of 20 runs.
- **SC-002**: A workspace with one nightly workflow and a 30-minute idle stop is up for less than
  1 hour a day when nothing else uses it.
- **SC-003**: Each due time starts a workspace at most once.
- **SC-004**: The three clients show the same next start on a host's row.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md` — change: "Starting the machines hosts run on" adds the
  wake-up call; a host sends its next due time with its idle status.
- `docs/how-to/start-workspaces-from-agents.md` — change: scheduled workflows start a stopped
  workspace; the switch; the warning is gone.
- `docs/reference/workflows.md` — change: the schedule row says a stopped workspace is started
  for it; a Mac or a host with the switch off still misses it.

## Assumptions

- Only workspaces linked to a provider get wake-up calls. Hosts with no provider (a Mac, a
  server with no provider) are as today.
- The control plane runs on the Mac until #61. While the Mac sleeps, no wake-up calls are made.
- A schedule's times are already known to the host (`nextDue`), so the host can send the next
  one without new rules.
- The idle stop, its time and its rules (#691 US4) don't change, except FR-005.
- Cost: a workspace runs for its start time plus the run plus its idle time for each wake-up
  call. Alex accepts this by having a schedule on a workspace; the switch (FR-009) turns it off.
