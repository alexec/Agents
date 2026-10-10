---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every event the app records, what it carries, and where you can see them, wait for them and trigger on them.
---

# Events

An event is something that happened: an agent finished, a branch moved, the Mac woke up. The app records each one. This page lists them all.

The same names work in three places:

- an agent's `wait_for_event` tool, to be started again when one happens, or when its
  time limit of 1 minute to 24 hours runs out, which every wait has (see
  [Have an agent wait for something](../how-to/wait-for-something.md)),
- a workflow's `on:`, to start an agent when one happens (see
  [Workflow triggers and actions](workflows.md)),
- the **Events** page, where you read what happened.

## Names and filters

A name is a subject, a dot, and what happened: `branch.moved`. A subject followed by `.*`,
such as `agent.*`, matches every event of that subject.

Each event is described the way an MCP server describes its own (`events/list`): a name, a
description, an `inputSchema` and a `payloadSchema`, both JSON Schema. The tables below
give them as two columns:

- **Details** are the `payloadSchema`: what the event carries, shown on the Events page, in
  a woken agent's message and in a workflow agent's prompt. Every detail is text; one with
  fixed values, such as `outcome`, `reason`, `by`, `how` or `level`, lists them as an
  `enum`. An event about an agent also carries `agent_title`, its title, beside `agent`, its
  id, and a woken agent is told both under those names.
- **Filter by** is the `inputSchema`: what a wait's `where` or the keys under a trigger can
  narrow the event by. Only a few events take any:
  - `branch` on `branch.moved`, for example `branch: main` for one branch;
  - `why` on `person.away` and `person.back`: `locked` or `idle`;
  - an MCP server's event's own, which the server checks (see
    [Events from MCP servers](#events-from-mcp-servers)).

Nothing else narrows an event: not `agent`, `labels`, `outcome` or any other detail of an
agent event, nor a drop box arrival's, a lease's, the disk's, a cost's or a server's, nor
a custom event's own. A custom event's `inputSchema` is empty and its `payloadSchema` open.

- **A list means any of them.** `branch: [main, develop]` matches either. A list of one is
  the same as the value on its own.
- **Filters are checked against the `inputSchema`** by the same checker as an MCP server's
  event's, so the sentences read alike. Any other key is an error naming what the event
  takes: *branch.moved takes branch; "to" is not one of its arguments.* For an agent event
  it says how to wait for particular agents instead: *agent.finished takes no arguments;
  "outcome" is not one of its arguments. To wait for particular agents, use wait_for_event
  with agents.* A workflow file with one is unreadable, and says so, rather than firing for
  every event of its kind.
- **A wrong value is an error too**: *person.away: why is one of locked, idle, not asleep.*
  `branch` takes any value.
- **A wait already waiting** when this changed keeps matching as it was written.

### The one list

`wait_for_event` with action `list` gives every event an agent can wait on, in one list: the
app's, then each of the project's MCP servers' that it offers by poll. Each is one line of
JSON with its `name`, `source` (`app`, or the server's name in `mcp.json`), `description`,
`inputSchema` and `payloadSchema`. A server that could not be asked is named on a line of
its own. The workflow tool's description carries the app's part of the same list.

Serving the app's own events over `events/poll` from the app's MCP endpoint, so any MCP
client could subscribe to them, would be possible in this shape; it is not done.

An agent can wait for its own project's events and for this Mac's. It cannot wait for
another project's events.

## Agents

All are about agents in the same project. None takes a filter: to wait for particular
agents, use `wait_for_event` with `agents`. Each shows:

- `agent`, the agent's id;
- `labels`, the agent's labels;
- `runtime`, its runtime: `claude`, `codex`, `gemini`, `grok` and the others this version knows;
- `started_by`: `person` (you, on the Mac, the phone or the web page), `workflow` (a workflow
  started it or resumes it), or `agent` (another agent started it as its helper).

These describe the agent as it was when the event happened. A label added later doesn't change
an event already on the log.

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `agent.started` | — | agent | An agent started working. |
| `agent.finished` | — | agent, outcome, afterwards | An agent ended a turn having done its work. `afterwards` is `archive_requested` when the turn ends asking to be archived, `archived` when the session is archived as the turn ends, else `stay`. `outcome` is `done`, `nothing_to_do`, `needs_answer`, `partly_done`, `stuck` or `blocked`. |
| `agent.asked_permission` | — | agent | An agent is asking for permission. |
| `agent.asked_form` | — | agent | An agent raised a form to fill in. |
| `agent.blocked` | — | agent, waiting_on | An agent ended its turn waiting on something. When `waiting_on` names agents or a time to check again, the agent resumes by itself; otherwise it needs you to carry it on. See [Statuses and groups](statuses.md). |
| `agent.stopped` | — | agent, by | An agent was stopped before finishing. `by` is `you`, `cost_limit` or `unknown`. |
| `agent.failed` | — | agent, reason | An agent ended in an error. `reason` is `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `max_turn_requests`, `refusal`, `daemon_gone`, `stopped_by_agent` or `unrecognised`. |
| `agent.archive_requested` | — | agent, outcome | An agent's turn ended asking for its session to be archived, and it waits for you to agree. `outcome` is its last report's, when it made one. |
| `agent.messaged` | — | agent, from, from_title | An agent was sent a message by another agent with `message_agent`. `agent` is the one it was sent to; `from` is the sender's id and `from_title` its title. |
| `agent.archived` | — | agent, by, outcome | An agent was archived. `by` is `you`, or `agent` when the agent that started it archived it with `archive_agent`. `outcome` is its last report's, when it made one. |
| `agent.deleted` | — | agent, because | An archived agent was deleted with its conversation. `because` is `age` or `person`. |

## Projects

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `project.idle` | — | agents, finished, blocked, waiting_on_you, stopped, failed, since, ids | Every agent in this project has stopped working. Raised once, a minute after the last agent stops, when none has started since. `agents` is how many worked since the project was last quiet, and `ids` their ids, comma-separated. `finished`, `blocked`, `waiting_on_you`, `stopped` and `failed` count how each of those stands now. `since` is when the first of them started. |

An agent asking for permission is not working, so it does not hold `project.idle` back: it
is counted under `waiting_on_you`. The agent a workflow on `project.idle` (or `project.*`)
runs, and any helper it starts, is not counted as work, so the clean-up finishing does not
raise `project.idle` again. A busy period is kept in memory: a restart of the app starts
counting again from the next agent that works.

## Workflows

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `workflow.ran` | — | workflow, agent | A workflow started an agent. |
| `workflow.completed` | — | workflow, agent, outcome | A workflow's run finished. `outcome` is its agent's report's, when it made one. |
| `workflow.refused` | — | workflow, reason | A workflow did not run, and why. `reason` is `run_in_flight`, `queue_full`, `chain_too_deep`, `archived`, `over_limit`, `unreadable`, `trigger_not_supported`, `agent_unavailable`, `no_triggering_agent`, `missed_while_closed`, `folder_gone`, `day_limit_reached`, `setting_refused` or `awaiting_approval`. |

## Branches

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `branch.moved` | branch | branch, from, to | A branch moved: the default branch, or one an agent works on. |

## Drop box

Each project has a drop box, the folder `.agents/dropbox/` in it. See
[Hand files to a workflow](../how-to/hand-files-to-a-workflow.md).

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `dropbox.file_added` | — | path, name, folder, extension, size | A file arrived in this project's drop box, or a folder in it. `path` is the file's full path on the project's host. `name` is its name. `folder` is where it is inside `.agents/dropbox/`, such as `review` or `review/2026`, and empty at the top. `extension` is in lower case without the dot, and empty when there is none. `size` is in bytes. Raised once, when the file has stopped changing. A file replaced under the same name, or changed where it lies, is raised again. Files there when the app starts, and names starting with a dot, are not. |

## This Mac

These belong to the machine the host runs on, not to a project. Any agent can wait for them.

`mac.sleep`, `mac.wake`, `person.away` and `person.back` are raised only on a Mac: a Linux
server has nothing that hears them. On a server, a `wait_for_event` naming only these is
refused, one naming them with others says so in its answer, and `manage_workflows` says so
when it writes or lists a workflow that triggers on them. The disk events fire on both, so
they are `machine.`.

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `lease.granted` | — | resource, agent | An agent was given a lease. See [Leases on shared resources](../explanation/leases.md). |
| `lease.released` | — | resource, how | A lease was given back, ended or ran out. `how` is `released`, `ended` or `expired`. |
| `mac.sleep` | — | | The Mac is going to sleep. Mac only. |
| `mac.wake` | — | | The Mac woke up. Mac only. |
| `machine.disk_low` | — | volume, free_bytes, free_percent, level, threshold, worktrees | Free space on a volume holding the Agents root, a project or a worktree fell below its threshold. `level` is `low` (below 20 GB or 5% of the disk, whichever is more) or `critical` (below 2 GB, where commands start failing). `threshold` is the line it fell below, in bytes. `worktrees` names the largest worktrees on the volume and their sizes, measured within a budget, so `over` means at least. Raised once per crossing; falling further from low to critical is a second crossing. The window shows a strip across the top while it lasts. On a Linux server the volume is called "This server’s disk". |
| `machine.disk_ok` | — | volume, free_bytes, free_percent, threshold | Free space on a volume that was low climbed back above its threshold, by a margin of a tenth of it (at least 1 GB) so it does not flap. |
| `person.away` | why | why | You locked the screen or stepped away for 5 minutes. `why` is `locked` or `idle`. Mac only. |
| `person.back` | why | why | You unlocked the screen or came back. `why` is `locked` or `idle`. Mac only. |
| `cost.limit_reached` | — | limit, agent | A spending limit was reached. When it is an agent's, it also carries `labels`, `runtime` and `started_by`. See [Settings and the Resources page](settings.md). |
| `cost.allowance_out` | — | runtime, until, retry_after, reason | A runtime's allowance ran out, its credit was used up, or it failed. `until` is the time the provider gave, when it gave one; `retry_after` is when the app next checks it. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| `cost.allowance_back` | — | runtime, how | A runtime is back: `check` (the app's check passed), `person` (Mark available), `worked` (a turn on it worked), `time` (a rate limit's wait passed) or `another host` (a server said so). |
| `server.offline` | — | server | A server's connection dropped. Raised once, while the Agents window is open. |
| `server.online` | — | server | A server that was offline is back. Raised once, while the Agents window is open. |

## Custom events

An agent can publish an event of its own with its `publish_event` tool, to tell other
agents and workflows in the same project that something happened.

- The name is `custom.` followed by up to 40 lowercase letters, digits and `_`, such as
  `custom.build_green` or `custom.release_ready`.
- It carries `publisher` and `message`, a short note of up to 500 characters for whoever
  wakes on it, plus up to 10 details of the publisher's own. These are shown, not filters.
- Each agent can publish at most 30 an hour.
- Only `custom.` events can be published. The others are raised by the app.

The publishing agent is told who was woken and which workflows ran.

## Events from MCP servers

An MCP server can offer events of its own, such as `checks.failed` or `pr.merged`. The app
asks for them the way the MCP events draft (`experimental-ext-triggers-events`) describes,
in poll mode, and only for servers whose `initialize` declares the `events` capability. See
[Start a workflow from an MCP event](../how-to/start-a-workflow-from-an-mcp-event.md).

- **Names.** A server's event is `noun.verbed`, lowercase, with no prefix, the same shape as
  the app's own. A name in the app's catalogue is always the app's. A server's event whose
  noun is one of the app's subjects (`agent`, `project`, `workflow`, `branch`, `lease`,
  `mac`, `machine`, `person`, `cost`, `server`, `custom`) is refused, so a server can never
  pose as the app.
- **Which servers.** The servers a project's agents get: the project's `.agents/mcp.json`
  once approved, your `~/.agents/mcp.json`, and plugins. A trigger without `server:` hears
  every one that offers the name; `server:` narrows it. A local (stdio) server is run by the
  app, as its own copy, to ask for events.
- **Filters are the server's.** The keys under a trigger are sent to the server as the
  subscription's arguments, checked against the event's own filter schema. A list is a list
  argument, not "any of".
- **Asked for while something listens.** Only for workflows that are on, not archived,
  approved, and run on this Mac or server, and for agents' open waits. Two workflows, or a
  workflow and a wait, with the same server, event and filters share one subscription. It
  ends when the last of them goes.
- **Pace.** As often as the server asks, but never more than every 10 seconds, and at least
  every 5 minutes; every 30 seconds when it doesn't say. Each subscription is asked on its
  own, so a slow server never holds another up.
- **Once each.** Each event is recorded once, by the server's event id, and runs each
  workflow that heard it once, across restarts. The app keeps where each subscription has
  got to in `mcp-events.json` in its own folder.
- **Starts from now.** A new subscription, or one whose filters changed, skips events from
  before it.
- **Missed events.** When the app was away longer than the server keeps events, the
  trigger's line says **Events may have been missed since …**, and the next event carries a
  `missed_since` detail. The events it did get still run.
- **Data is data.** The event's data is passed to the agent after the workflow's prompt,
  in a fenced block, marked as coming from the server and not from you. Data over 256 KB is
  cut, and the event says so.
- **Push and webhook** delivery are not taken yet. An event offered only that way is shown
  as not supported.

A server's event carries:

| Detail | What it is |
| --- | --- |
| `server` | The server it came from, by its name in `mcp.json` |
| `event` | Its name, such as `checks.failed` |
| `subscription` | The subscription's key: a digest of the server, the event and its filters |
| `mcp_event_id` | The server's id for it |
| `time` | When the server says it happened |
| `payload` | The event's data, as compact JSON, at most 256 KB |
| `payload_cut` | `true` when the data was cut |
| `missed_since` | On the first event after a gap, when events may have been missed from |

A wait on a server's event, such as `checks.failed` or `checks.*`, is a subscription, as a
trigger is:

- **Checked when it is made.** The name is checked against what the project's servers offer
  (`events/list`). If none offers it, the wait is refused, saying what each one does offer:
  *No server here offers pr.merge. ci offers checks.failed, pr.merged.*
- **`where` is the server's.** Its keys are the subscription's arguments, sent to the server
  and checked against the event's filter schema, as a trigger's are: *ci's pr.merged takes
  repo (required); repo is needed.* They are not matched against the event's details.
  `server:` narrows it to the servers named.
- **It subscribes for as long as it waits**, from now, sharing a workflow's subscription
  when they ask for the same thing. When it is answered, times out or is cancelled, the
  subscription ends unless a workflow or another wait still holds it. A restart keeps it.
- **A server that can't be reached, or isn't approved yet,** is a warning, not a refusal:
  the wait subscribes once the server can be asked.

The wait's answer and its line under **Waiting now** say which servers it subscribed to:
**Waiting for pr.merged on ci (repo alexec/Agents)**.

Each workflow page shows a line for each server its event triggers hear, on the Mac, the
iPhone and iPad and the web page: when it was last asked and when the last event came, or
why not (**Can't reach ci**, the server no longer offers the event, refused it, or doesn't
take the filters).

## The Events page

On the Mac, **Events** is a row at the foot of the sidebar, above **Resources** and
**Spending**. It shows every event, newest first, grouped by day.

- **Filters**: a menu for all projects, this Mac or one project, and a capsule for each
  subject: **Agents**, **Workflows**, **Branches**, **Drop box**, **This Mac** and
  **Custom**.
- **Each row** shows the time, what happened, and the event's name. Under it, what it led
  to: **Woke** an agent, **Fired** a workflow, **Refused by** a workflow with the reason,
  or **Could not wake** an agent with the reason. A repeat shows a count, such as ×4.
- **Click a row** to see every detail it carries. **Copy as trigger** copies it as a
  workflow's `on:` line, narrowed by the event's filters only: `branch` on a
  `branch.moved`, `why` on a `person.away` or `person.back`. Every other event is copied
  as its name alone.
- **Waiting now**, at the top, lists every agent that is waiting for an event, what for
  and until when, with ✕ to end the wait. It is not shown when nobody is waiting.

On the iPhone and iPad, **Events** is a row under the project list. It shows the same rows
and details, filtered by one menu. It has no subject capsules, no **Copy as trigger** and
no **Waiting now**.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Hand files to a workflow](../how-to/hand-files-to-a-workflow.md)
- [Set up a workflow](../how-to/set-up-a-workflow.md)
- [Workflow triggers and actions](workflows.md)
- [Tools the app gives agents](agent-tools.md)
- [Statuses and groups](statuses.md)
