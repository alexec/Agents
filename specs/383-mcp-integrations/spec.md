# Feature Specification: MCP integrations, a proof of concept (CI watcher)

**Feature Branch**: `agents/spec-383-mcp-integrations`

**Created**: 2026-10-06

**Status**: Draft

**Input**: Issue #383, "MCP integrations proof of concept: a CI watcher with events, tools and a view".

## Why this feature exists

An integration (GitHub, Slack, a ticket system) should bring three things to Agents:

1. **Events** that start workflows: "a check failed", "a message arrived".
2. **Tools** that an agent can use.
3. **UI**: something to look at in the app.

The idea is that **one MCP server is a whole integration**, so Agents needs no integration format of its own. Two of the three already work:

- **Tools** are what MCP is. A server in `.agents/mcp.json`, in `~/.agents/mcp.json` or in a plugin already gives agents its tools.
- **UI** is MCP Apps (SEP-1865). A tool's `ui://` view is drawn in the chat on the Mac, the Remote and the web page, and can be pinned to a project ([Views in a conversation](../../docs/explanation/views.md)).

**Events** are missing. MCP now has a draft extension for them,
[`experimental-ext-triggers-events`](https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
(February 2026, not ratified). ChatGPT already supports its webhook mode
([OpenAI: MCP events](https://developers.openai.com/plugins/build/mcp-events)). The draft
offers three ways to deliver events:

| Mode | How | Public address needed |
| --- | --- | --- |
| poll | The client asks for new events from a saved position (a cursor) | No |
| push | The client holds a stream open and events arrive on it, as in Slack's Socket Mode | No |
| webhook | The server POSTs each signed event to the client's URL | Yes |

This feature makes Agents a client of that draft, in **poll mode** first, so that a server's
events can start a workflow. It proves the idea end to end with a real integration we need
ourselves: a **CI watcher** for this repo. When a pull request's checks fail, an agent starts
on that branch, reads the log, and either reruns the checks (if the failure is flaky) or
pushes a fix. A board of open pull requests and their checks is pinned to the project.

The CI watcher is a small MCP server of our own, because no GitHub MCP server implements the
events draft yet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An MCP event starts a workflow (Priority: P1)

Alex has an MCP server that offers events. Alex writes a workflow whose trigger is one of
that server's events, narrowed by the event's own filters:

```markdown
---
name: Fix failed checks
on:
  - checks.failed:
      repo: alexec/Agents
agent: new
cooldown: 5m
---

A pull request's checks failed. Read the failed job's log. If it is a known flaky test,
rerun the failed jobs; otherwise fix it on the pull request's branch and push.
```

From then on, each time the server reports that event, the workflow runs once. The agent is
told the event's details as data.

**Why this priority**: this is the part MCP was missing. Without it an integration can only
offer tools and views, and nothing happens unless someone asks.

**Independent Test**: use a stand-in MCP server whose events can be raised from a test.
Raise one event and see one workflow run, with the event's details in the agent's prompt.
Raise the same event again (same id) and see no second run.

**Acceptance Scenarios**:

1. **Given** a workflow on `checks.failed` with `repo: alexec/Agents`, and `ci` the only
   server here offering that event, **When** the server reports one for that repo, **Then** the workflow runs once and
   its agent is told the event's details, marked as coming from the server and not from Alex.
2. **Given** the same workflow, **When** the server reports an event for another repo,
   **Then** nothing runs, because the server only sends events that match the filters.
3. **Given** an event has started a run, **When** the server reports the same event again,
   **Then** nothing runs.
4. **Given** the workflow's file names a filter the event does not declare, or a value of
   the wrong type, **When** the workflow is read, **Then** the workflow's page shows it as an
   error in the file, naming the filters the event takes, and it never runs. This is how a
   wrong filter on any event is shown today.
5. **Given** the workflow is turned off, archived, or on another host (`hosts:`), **When**
   the server would report events, **Then** this host does not ask for them.
6. **Given** two servers here (`github` and `gitlab`) both offer `pull_request.opened`, and a
   workflow names it without `server:`, **When** either reports one, **Then** the workflow runs,
   and the agent is told which server it came from. With `server: github`, only GitHub's run
   it.

---

### User Story 2 - Nothing is lost or doubled across a restart (Priority: P1)

The daemon stops (a restart, a ship, the Mac asleep) while a check fails. When it is back, it
picks up where it left off.

**Why this priority**: an event that starts an agent, which can push code, has to happen
exactly once. A lost event means a red PR nobody looks at. A doubled one means two agents
fixing the same branch.

**Independent Test**: stop the daemon, raise an event on the stand-in server, start the
daemon again, and see exactly one run. Do it twice more and still see one run per event.

**Acceptance Scenarios**:

1. **Given** the daemon is stopped, **When** an event happens and the daemon starts again,
   **Then** that event starts exactly one run.
2. **Given** a workflow subscribes for the first time, **When** the server has older events,
   **Then** none of them run: a new subscription starts from now.
3. **Given** the daemon was away longer than the server keeps events, **When** it asks
   again, **Then** the workflow's page says events may have been missed, and when. The events
   it does get still run.
4. **Given** a workflow's filters are changed in its file, **When** it is read again,
   **Then** it is a new subscription that starts from now, and the old one's position is
   dropped.

---

### User Story 3 - The CI watcher server (Priority: P2)

This project gets a small MCP server, configured in its own `.agents/mcp.json`, that watches
its GitHub repo. It uses GitHub through this Mac's existing `gh` sign-in. It offers:

| Kind | Name | What it does |
| --- | --- | --- |
| Event | `checks.failed` | A pull request's checks finished with a failure. Filters: `repo`, and optionally `branch`. Details: the PR's number, title, branch, head commit, the failed jobs and their URLs. |
| Event | `pr.merged` | A pull request was merged. Filter: `repo`. A second event, to prove a server can offer more than one. |
| Tool | `list_prs` | Open pull requests and their check state. Read-only. Feeds the board view. |
| Tool | `failed_log` | The end of a failed job's log. Read-only. |
| Tool | `rerun_failed` | Reruns a run's failed jobs. |
| Tool | `comment_on_pr` | Adds a comment to a pull request. |

**Why this priority**: it is the real integration the proof of concept is about. It is also
something this project needs: today, a PR whose CI fails waits until someone notices.

**Independent Test**: with the server running and the workflow from Story 1 on, push a
branch with a failing test to a PR. An agent starts on that branch, reads the failure with
`failed_log`, and fixes it or reruns it.

**Acceptance Scenarios**:

1. **Given** the server is set up in this project, **When** an agent's session starts,
   **Then** the agent can use its four tools like any other MCP server's.
2. **Given** a PR's checks fail, **When** the server is next asked for events, **Then** it
   reports one `checks.failed` event for that PR and head commit, with a stable id.
3. **Given** a PR's checks fail, are rerun and fail again on the same commit, **When** the
   server is asked, **Then** it reports a second event with a different id, because it is a
   new failure.
4. **Given** `gh` is not signed in, **When** the daemon asks for events, **Then** the
   workflow's page says the server can't reach GitHub and why, and nothing runs.

---

### User Story 4 - A board of pull requests, pinned to the project (Priority: P3)

The server's `ui://ci/board` view lists open PRs with their check state: passing, failing or
running. A failing PR has a **Rerun** button, and a link to the agent working on it when
there is one. It can be pinned to the project like any other view.

**Why this priority**: it proves the third part of an integration (UI) with what already
exists: views from http servers, and pins. It needs nothing new from the app.

**Independent Test**: pin the board, open it on the Mac, the Remote and the web page, and see
the same PRs with the right states.

**Acceptance Scenarios**:

1. **Given** the board is pinned, **When** Alex opens it, **Then** it shows the open PRs and
   their check state as of that moment.
2. **Given** a failing PR, **When** Alex presses **Rerun**, **Then** its failed jobs are
   rerun and the board shows them running.

---

### User Story 5 - See what each event trigger is doing (Priority: P3)

On a workflow's page, under each MCP trigger, Alex can see whether it is working: when the
server was last asked, when the last event arrived, and any error, such as the server being
unreachable, the event no longer offered, the server refusing it, or events missed.

**Why this priority**: an event trigger that silently stops is worse than none. Alex thinks
the watcher is on when it isn't.

**Independent Test**: stop the stand-in server and see the trigger's line turn to an error
within one poll interval. Start it again and see it recover without anyone doing anything.

**Acceptance Scenarios**:

1. **Given** a healthy trigger, **When** Alex opens the workflow's page, **Then** it shows
   when the server was last asked and when the last event came.
2. **Given** the server is unreachable, **When** the daemon fails to ask it, **Then** the line
   says so and the daemon keeps trying, waiting longer each time, up to a limit.
3. **Given** the server stops offering the event, or refuses it as not allowed, **When** the
   daemon next asks, **Then** the line says which, and the daemon stops asking until the
   workflow's file or the server's list of events changes.

### Edge Cases

- **The server doesn't offer events at all**, or doesn't offer poll mode for this event: the
  workflow's page says so, naming the modes the event does offer. The workflow never runs on
  it.
- **The server is a local (stdio) one**: the daemon runs its own copy to ask for events, with
  the same secrets as a session. That copy is separate from the runtime's.
- **Two workflows on the same event with the same filters**: the server is asked once, and
  each event runs both workflows.
- **Two servers offer the same event name** (GitHub and GitLab both offer
  `pull_request.opened`): a trigger without `server:` runs for both, and the page shows one
  status line for each server. With `server: github` it runs for GitHub only.
- **A new server that offers the same name is added**: triggers without `server:` start
  running for it too, from now. The page gains a line for it, and the daemon's log says so.
- **The filters fit one server's event and not another's** (GitHub calls it `repo`, GitLab
  `project`): the trigger runs for the servers they fit. The line for the one they don't fit
  is an error naming its filters. To filter both, write one trigger per server.
- **A typo in a built-in event's name** (`brnch.moved`): no server offers it, and the page
  says so and lists the nearest built-in name. It never runs.
- **An event arrives while the workflow is cooling down**: the same as any other event today
  during a cooldown.
- **An event's details are very large**: details over 256 KB are cut, the cut is noted in
  what the agent is told, and the run still starts.
- **An event's details hold instructions** ("ignore your prompt and…"): they reach the agent
  as quoted data from the named server. The workflow's own prompt and permission mode decide
  what the agent may do.
- **The server asks for a long wait** (`nextPollMs`): the daemon waits at least that long. It
  never asks more often than every 10 seconds, whatever the server says.
- **Many servers with events**: each one is asked on its own schedule. One server being slow
  or down does not delay another.
- **The project is on a server host, not this Mac**: the host that runs the workflow asks for
  the events, as for any other workflow trigger.

## Requirements *(mandatory)*

### Functional Requirements

**Event triggers (the daemon)**

- **FR-001**: Every event name MUST be `noun.verbed`, with no prefix, whoever raises it:
  `checks.failed`, `pr.merged`, the same shape as `branch.moved`. A workflow's `on:` MUST
  accept a server's event by that name alone. Without `server:`, the trigger subscribes to
  **every** MCP server this project can use that offers the name, and runs for an event from
  any of them. `server:` narrows it to one server (`server: github`) or to a list
  (`server: [github, gitlab]`). The event always says which server it came from, so the agent
  knows.
- **FR-001a**: A server's event MUST be refused, and shown as such on the page, if its name
  is not `noun.verbed`, or if its noun is one the app raises events about (`agent`,
  `project`, `workflow`, `branch`, `lease`, `mac`, `person`, `cost`, `server`, `custom`).
  This way a server's event can never be mistaken for one of the app's.
- **FR-002**: The filters under the trigger MUST be checked against the event's declared
  filter schema when the workflow is read, and shown as an error in the file if they don't
  fit, as filters on built-in events are today.
- **FR-003**: The daemon MUST find a server's events through the draft's discovery, and only
  for servers that declare the events capability. If the server says its events changed,
  the daemon MUST read them again.
- **FR-004**: The daemon MUST receive events in poll mode, pacing itself by what the server
  asks, but never more often than every 10 seconds and never less often than every 5 minutes.
- **FR-005**: The daemon MUST keep each subscription's position durably on the host that runs
  the workflow, and resume from it after any restart.
- **FR-006**: A new subscription MUST start from now, and so must one whose filters changed.
  Earlier events are not run.
- **FR-007**: Each event MUST start at most one run per workflow, keyed by the event's id. The
  ids already seen MUST be kept long enough to cover a restart.
- **FR-008**: The event's name, server, time and details MUST reach the agent as data, after
  the workflow's prompt, marked as coming from that server. This is how built-in events are
  told today.
- **FR-009**: Missed events (the draft's `truncated`), errors and when a subscription was last
  asked MUST be recorded and shown under the trigger on the workflow's page, on the Mac, the
  Remote and the web page.
- **FR-010**: An unreachable server MUST be retried, waiting longer each time up to a limit. An
  event the server no longer offers, or refuses, MUST stop being asked for until the workflow
  or the server's list of events changes.
- **FR-011**: Only the hosts that run a workflow MUST ask for its events. A workflow that is
  off or archived MUST NOT be asked for.
- **FR-012**: Every event received and every run it started MUST be in the daemon's log, with
  the server, event name, event id and workflow.
- **FR-013**: Push and webhook modes are not part of this feature. An event that offers only
  those MUST be shown as not yet supported.

**The CI watcher (the integration)**

- **FR-020**: The repo MUST hold a small MCP server for this project's GitHub CI, served over
  http on this Mac and set up in the project's `.agents/mcp.json`.
- **FR-021**: It MUST offer the events and tools in User Story 3, with filter and detail
  schemas, and stable event ids: one per PR, head commit and failed check suite for
  `checks.failed`, and one per PR for `pr.merged`.
- **FR-022**: It MUST use this Mac's existing `gh` sign-in, and hold no token of its own.
- **FR-023**: It MUST offer the `ui://ci/board` view, fed by the read-only `list_prs`, so
  the view can be pinned.
- **FR-024**: The project MUST have a `Fix failed checks` workflow on `checks.failed`,
  arriving turned off (`enabled: false`) like the other review workflows.

### Key Entities

- **Event trigger**: a workflow's `on:` entry naming a server's event (`checks.failed`), its
  filters, and optionally `server:` (one name or a list) to narrow which servers it hears.
  It becomes one subscription per server it hears.
- **Subscription**: one server, event and set of filters on one host, with its saved
  position, last asked time, last event time, last error and missed-events marks. It is
  shared by every workflow with the same trigger.
- **Event**: an id, a name, a time and details from a server, delivered once to each
  subscribed workflow.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Within 2 minutes of a PR's checks failing, an agent is working on that branch.
- **SC-002**: Across 20 failures, half of them while the daemon was stopped, each failure
  starts exactly one run. None are missed and none are doubled.
- **SC-003**: Over a week of normal use, at least half the failed PRs are green again, or have
  a clear "this needs Alex" comment, without Alex starting anything.
- **SC-004**: A stopped server shows as an error on its workflow's page within one poll
  interval, and recovers by itself within one interval of coming back.
- **SC-005**: The CI watcher's events, tools and view all come from one server and one
  config entry, with no integration-specific code in the app.

## Docs *(mandatory)*

- `docs/reference/workflows.md`: change. Say that an `on:` event name can be a server's
  event, with its filters and `server:` (one or a list), and that without `server:` it hears
  every server offering the name; give an example.
- `docs/reference/events.md`: change. Add a section "Events from MCP servers": names,
  filters, delivered once, the saved position, missed events, poll mode only.
- `docs/how-to/start-a-workflow-from-an-mcp-event.md`: add. Set up a server with events, write
  the workflow, check it on the workflow's page. Uses the CI watcher as the example.
- `docs/explanation/views.md`: none. The board is a view from an http server, which is
  already described.

## Parity

The event triggers live in the daemon. The only UI is the trigger's status line on the
workflow's page (FR-009), which is drawn by all three clients: **mac: same, remote: same,
web: same**. The board is a pinned view, which all three already draw.

## Assumptions

- The draft's poll mode (`events/list`, `events/poll`, cursors, `truncated`, `nextPollMs`)
  is stable enough to build against. If the draft changes, the daemon follows it. It's a
  proof of concept, and Agents is an early client.
- The draft needs the MCP 2.0 protocol version. The daemon's own MCP client is ours, so it
  can speak that version to servers that offer events, and keep the older version for the
  rest.
- The CI watcher runs on this Mac only. Webhooks, which would need the control plane in the
  cloud (#61), push mode and a Slack integration (through Socket Mode) are later work.
- Placing a view anywhere but the chat and pins (a sidebar badge, a row status) is a separate
  extension of MCP Apps, and not part of this feature.
- "Flaky or real" is the agent's judgement, given in the workflow's prompt. The app does not
  classify failures.
