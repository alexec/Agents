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
  - `branch` on `branch.moved`, for example `branch: agents/fix-640` for one branch. It is
    raised only for a branch an agent works on, never the default branch (#702), and a wait
    on the default branch is refused: wait for the `github` server's `pr.merged` instead;
  - `why` on `person.away` and `person.back`: `locked` or `idle`;
  - an MCP server's event's own, which the server checks (see
    [Events from MCP servers](#events-from-mcp-servers)).

Nothing else narrows an event: not `agent`, `labels`, `outcome` or any other detail of an
agent event, nor a drop box arrival's, a lease's, the disk's, a cost's or a server's.

- **A list means any of them.** `branch: [main, develop]` matches either. A list of one is
  the same as the value on its own.
- **Filters are checked against the `inputSchema`** by the same checker as an MCP server's
  event's, so the sentences read alike. Any other key is an error naming what the event
  takes: *branch.moved takes branch; "to" is not one of its arguments.* For an agent event
  it says how to wait for particular agents instead: *agent.finished takes no arguments;
  "outcome" is not one of its arguments. To wait for particular agents, use wait_for_agents.* A workflow file with one is unreadable, and says so, rather than firing for
  every event of its kind.
- **A wrong value is an error too**: *person.away: why is one of locked, idle, not asleep.*
  `branch` takes any value.
- **A wait already waiting** when this changed keeps matching as it was written.

### What an agent can wait on

An unknown event name is refused, and the refusal names the events that are offered: the
app's, then each of the folder's MCP servers' that it offers by poll. The workflow tool's
description carries the app's part of the same list.

Serving the app's own events over `events/poll` from the app's MCP endpoint, so any MCP
client could subscribe to them, would be possible in this shape; it is not done.

An agent can wait for its own folder's events and for this Mac's. It cannot wait for
another folder's events. To wait for particular sessions, it calls `wait_for_agents`. To
resume at a time, it calls `check_again`.

## Agents

All are about agents in the same folder. None takes a filter: to wait for particular
agents, use `wait_for_agents`. Each shows:

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
| `agent.finished` | — | agent, outcome, afterwards | An agent ended a turn having done its work. `afterwards` is `archive_requested` when the turn ends waiting for you to approve archiving it, `archived` when the session is archived as the turn ends, else `stay`. `outcome` is `done`, `nothing_to_do`, `needs_answer` or `waiting` (#1916 removed `partly_done` and `stuck`). |
| `agent.asked_permission` | — | agent | An agent is asking for permission. |
| `agent.asked_form` | — | agent | An agent raised a form to fill in. |
| `agent.waiting` | — | agent, waiting_on | An agent ended its turn waiting on something. When `waiting_on` names agents or a time to check again, the agent resumes by itself. See [Statuses and groups](statuses.md). |
| `agent.stopped` | — | agent, by | An agent was stopped before finishing. `by` is `you`, `admin` (an admin in the Console, #2435), `cost_limit` or `unknown`. |
| `agent.failed` | — | agent, reason | An agent ended in an error. `reason` is `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `max_turn_requests`, `refusal`, `daemon_gone`, `stopped_by_agent` or `unrecognised`. |
| `agent.archive_requested` | — | agent, outcome | An agent's turn ended after `archive_session`, and its session waits for you to approve archiving it. `outcome` is its last report's, when it made one. |
| `agent.messaged` | — | agent, from, from_title | An agent was sent a message by another agent with `message_session`. `agent` is the one it was sent to; `from` is the sender's id and `from_title` its title. |
| `agent.archived` | — | agent, by, outcome | An agent was archived. `by` is `you`, or `agent` when the agent that started it archived it with `archive_session`. `outcome` is its last report's, when it made one. |
| `agent.deleted` | — | agent, because | An archived agent was deleted with its conversation. `because` is `age` or `person`. |

## Folders

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `folder.idle` | — | agents, finished, waiting, waiting_on_you, stopped, failed, since, ids | Every agent in this folder has stopped working. Raised once, a minute after the last agent stops, when none has started since. `agents` is how many worked since the folder was last quiet, and `ids` their ids, comma-separated. `finished`, `waiting`, `waiting_on_you`, `stopped` and `failed` count how each of those stands now. `since` is when the first of them started. |

An agent asking for permission is not working, so it does not hold `folder.idle` back: it
is counted under `waiting_on_you`. The agent a workflow on `folder.idle` (or `folder.*`)
runs, and any helper it starts, is not counted as work, so the clean-up finishing does not
raise `folder.idle` again. A busy period is kept in memory: a restart of the app starts
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
| `branch.moved` | branch | branch, from, to | A branch an agent works on moved; never the default branch. |

## Drop box

Each folder has a drop box, the folder `.agents/dropbox/` in it. See
[Hand files to a workflow](../how-to/hand-files-to-a-workflow.md).

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `dropbox.file_added` | — | path, name, folder, extension, size | A file arrived in this folder's drop box, or a folder in it. `path` is the file's full path on the folder's host. `name` is its name. `folder` is where it is inside `.agents/dropbox/`, such as `review` or `review/2026`, and empty at the top. `extension` is in lower case without the dot, and empty when there is none. `size` is in bytes. Raised once, when the file has stopped changing. A file replaced under the same name, or changed where it lies, is raised again. Files there when the app starts, and names starting with a dot, are not. |

## This Mac

These belong to the machine the host runs on, not to a folder. Any agent can wait for them.

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
| `machine.disk_low` | — | volume, free_bytes, free_percent, level, threshold, worktrees | Free space on a volume holding the Agents root, a folder or a worktree fell below its threshold. `level` is `low` (below 20 GB or 5% of the disk, whichever is more) or `critical` (below 2 GB, where commands start failing). `threshold` is the line it fell below, in bytes. `worktrees` names the largest worktrees on the volume and their sizes, measured within a budget, so `over` means at least. Raised once per crossing; falling further from low to critical is a second crossing. The window shows a strip across the top while it lasts. On a Linux server the volume is called "This server’s disk". |
| `machine.disk_ok` | — | volume, free_bytes, free_percent, threshold | Free space on a volume that was low climbed back above its threshold, by a margin of a tenth of it (at least 1 GB) so it does not flap. |
| `person.away` | why | why | You locked the screen or stepped away for 5 minutes. `why` is `locked` or `idle`. Mac only. |
| `person.back` | why | why | You unlocked the screen or came back. `why` is `locked` or `idle`. Mac only. |
| `cost.limit_reached` | — | limit, agent | A spending limit was reached. When it is an agent's, it also carries `labels`, `runtime` and `started_by`. See [Settings and the Resources page](settings.md). |
| `cost.allowance_out` | — | runtime, until, retry_after, reason | A runtime's allowance ran out, its credit was used up, or it failed. `until` is the time the provider gave, when it gave one; `retry_after` is when the app next checks it. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| `cost.allowance_back` | — | runtime, how | A runtime is back: `check` (the app's check passed), `person` (Mark available), `worked` (a turn on it worked), `time` (a rate limit's wait passed) or `another host` (a server said so). |
| `server.offline` | — | server | A server's connection dropped. Raised once, while the Agents window is open. |
| `server.online` | — | server | A server that was offline is back. Raised once, while the Agents window is open. |
| `system.restarted` | — | reason, down_since, down_for, down_for_text | Agents started again, on a Mac or a server. `reason` is `stopped` (a clean stop was recorded), `crashed` (it was alive and never said it stopped) or `first_start` (nothing was recorded). `down_since` is when it stopped or was last alive; `down_for` is the gap in seconds and `down_for_text` in words ("3 min", or "unknown"). See [Restarts](#restarts). |

## Restarts

A daemon that stops, crashes or is updated keeps what it can. It writes `alive.json` in the
Agents root once a minute, and its time when it stops cleanly (also when launchd stops it).
The next start works out from it how long nothing was running, and raises
`system.restarted`. A workflow can trigger `on: system.restarted`; a missed schedule is still
not run later.

What is had again after a restart:

- **Waits** are kept. A deadline that passed while it was down ends the wait as timed out; a
  wake queued and not sent is sent once.
- **Events from MCP servers** (`pr.merged`, `checks.failed`, …) continue from the cursor in
  `mcp-events.json`, once each.
- **`branch.moved`** compares the saved tips with the branches now.
- **The disk** and **the person** are looked at again. A crossing or a return that happened
  in the gap is raised then, with the detail `noticed: after_restart`.
- **The workflow queue** is kept.

What is not: events that happen once and that only the daemon sees, such as `agent.*`,
`lease.*`, `workflow.*`, `mac.sleep` and `mac.wake`. Nothing recorded them. `server.*` is told
by the Agents window, and a change while the daemon was down is not told again.

An agent whose wait was open over a restart is not woken only to be told. At its next wake,
by its event or its time limit, the wake says when Agents restarted, for how long it was down,
and which of the events it waits on may be missing, so it can check the state itself (the
branch or the pull request). A wait only on events that are had again says
that they were caught up. To be woken by the restart itself, wait on `system.restarted`.

## No custom events

Agents do not raise events of their own. The `publish_event` tool and the `custom.` events it
raised were removed (#639). A wait on a `custom.` name is refused, saying why, and a workflow
whose `on:` names one does not run: its page says what is wrong. To wait for another agent,
use `wait_for_agents`. A `custom.` event already on the log still shows, with the
agent that published it.

## Events from MCP servers

An MCP server can offer events of its own, such as `checks.failed` or `pr.merged`. The app
asks for them the way the MCP events draft (`experimental-ext-triggers-events`) describes,
in poll mode, and only for servers whose `initialize` declares the `events` capability. See
[Start a workflow from an MCP event](../how-to/start-a-workflow-from-an-mcp-event.md).

- **Names.** A server's event is `noun.verbed`, lowercase, with no prefix, the same shape as
  the app's own. A name in the app's catalogue is always the app's. A server's event whose
  noun is one of the app's subjects (`agent`, `folder`, `workflow`, `branch`, `lease`,
  `mac`, `machine`, `person`, `cost`, `server`, `custom`) is refused, so a server can never
  pose as the app.
- **Which servers.** The servers a folder's agents get: the folder's `.agents/mcp.json`
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
| `sender_channel`, `sender_identity` | On a channel message: who sent it (#1762) |
| `sender_user`, `sender_name` | On a channel message: the person its sender is linked to |

A server's event that carries `sender` is a channel message. It is raised only when its
sender is linked to a person, and an email only with an aligned DKIM pass. See
[Channels](channels.md).

A wait on a server's event, such as `checks.failed` or `checks.*`, is a subscription, as a
trigger is:

- **Checked when it is made.** The name is checked against what the folder's servers offer
  (`events/list`). If none offers it, the wait is refused, saying what each one does offer:
  *No server here offers pr.merge. github offers checks.failed, pr.merged.*
- **`where` is the server's.** Its keys are the subscription's arguments, sent to the server
  and checked against the event's filter schema, as a trigger's are: *github's pr.merged takes
  branch, pr, repo; "sha" is not one of its arguments.* They are not matched against the event's details.
  `server:` narrows it to the servers named.
- **It subscribes for as long as it waits**, from now, sharing a workflow's subscription
  when they ask for the same thing. When it is answered, times out or is cancelled, the
  subscription ends unless a workflow or another wait still holds it. A restart keeps it.
- **A server that can't be reached, or isn't approved yet,** is a warning, not a refusal:
  the wait subscribes once the server can be asked.

The wait's answer and its line under **Waiting now** say which servers it subscribed to:
**Waiting for pr.merged on github (repo alexec/Agents)**.

Each workflow page shows a line for each server its event triggers hear, on the Mac, the
iPhone and iPad and the web page: when it was last asked and when the last event came, or
why not (**Can't reach github**, the server no longer offers the event, refused it, or doesn't
take the filters).

## The Events page

On the Mac, **Events** is a row at the foot of the sidebar, above **Resources** and
**Spending**. It shows every event, newest first, grouped by day.

- **Filters**: a menu for all folders, this Mac or one folder, and a capsule for each
  subject: **Agents**, **Workflows**, **Branches**, **Drop box** and **This Mac**.
- **Each row** shows the time, what happened, and the event's name. Under it, what it led
  to: **Woke** an agent, **Fired** a workflow, **Refused by** a workflow with the reason,
  or **Could not wake** an agent with the reason. A repeat shows a count, such as ×4.
- **Click a row** to see every detail it carries. **Copy as trigger** copies it as a
  workflow's `on:` line, narrowed by the event's filters only: `branch` on a
  `branch.moved`, `why` on a `person.away` or `person.back`. Every other event is copied
  as its name alone.
- **Waiting now**, at the top, lists every agent that is waiting for an event, what for
  and until when, with ✕ to end the wait. It is not shown when nobody is waiting.

On the iPhone and iPad, **Events** is a row under the folder list. It shows the same rows
and details, filtered by one menu. It has no subject capsules, no **Copy as trigger** and
no **Waiting now**.

## Audit: who did what

The Events page has two panes, **Events** and **Audit**, on the Mac, the Remote and the web
page (#996). **Audit** shows what was done through the control plane, newest first by day.
It is read only.

- **Each entry** shows the time, what was done ("Stopped an agent"), who did it and with
  which client ("Local owner · MacBook Pro"), on which machine, and the call with what it
  acted on (`agents/stop · <agent>`).
- **The control plane writes the actor itself.** It uses the client it knows the call came
  from. It ignores an actor that a client puts in its request. It also gives the actor to
  the host when it opens the client's channel (`ChannelOpen.actor`).
- **The host writes it into `events.jsonl` (#1751).** An event that a person's call
  raised carries that channel's actor as `actor`, and its detail shows a **By** row on all
  three clients: `agent.started` from `agents/start`, `agent.stopped` from `agents/stop`,
  `agent.archived` from `agents/archive`, `agent.deleted` from `agents/delete`,
  `server.offline` and `server.online`, and an event raised by hand. What an agent, a
  workflow or the machine does has no actor, and neither does a call over `daemon.sock`.
  Answering a card raises no event, so it is only in the audit. The same event from two
  people is two events, not one with a count.
- **What is kept**: start, stop, archive or delete an agent or session; answer an approval,
  permission, question or sandbox card; change a setting, a cost limit or a folder's
  limits; approve, deny, run, turn on or off, or delete a workflow; approve a plugin; add,
  approve or remove an MCP server, a skill or a marketplace; add or delete a folder;
  pair, forget or remove a client or a machine; lend a sign-in or git access; change a
  machine provider. Reads, prompts and presence are not kept. An entry is written when
  the control plane passes the call on, so a call that the host refuses is kept too.
- **How long**: 90 days by default. An admin picks 30, 90, 180 or 365 days in the pane
  (`control/setAuditDays`, 1 to 3,650); the menu marks the time set now. The control
  plane's hourly sweep deletes older entries, by day. A shorter time asks first, with how
  many days (and, when every entry is loaded, how many entries) it deletes, and the sweep
  keeps the older days for one more day: choose the longer time again in that day and
  nothing is lost (#2067).
- **Whose** (an admin only): Everyone, or one person's entries (`audit/list` with `user`).
- **Export** saves the entries shown as CSV or as JSON lines (`audit/export`, at most
  50,000). On the Mac and the Remote, **Export…** is a menu with the two; the web page has
  **Export CSV** and **Export JSON lines**. Console ▸ Audit on the web page is the same pane
  (#2087).
- **Who sees what**: an admin sees every entry and a member sees only their own. Until
  people (#994) are built, a control plane has one person, the local owner. That person is
  the admin, and every client belongs to them.

Entries are stored in the control plane's store under `v1/events/<day>/`, one file each.
The methods are `audit/list`, `audit/export` and `control/setAuditDays`.

### The hash chain

Each entry is in a **chain** (#1001). Each copy of the control plane links the entries it
writes. An entry carries `chain` (the copy), `seq` (its place, from 1 when the copy
starts) and `prev` (the SHA-256 of the stored entry before it). Each hour, and when a day
ends, the copy writes a **seal** for the day under `v1/audit-seals/<day>/<copy>.json`: the
chain's last place and its hash. Seals go with their day's entries.

`agents-control audit verify` reads every entry and seal in the store. It says which
entry was changed and which were removed, and exits 1 when it finds any. A day that the
sweep deleted is not a removal. Entries written before the chain are counted, not checked.

The chain shows a change. It does not stop one: a person who can write the store can also
write a new chain. To keep a copy out of their reach, send the entries to a sink.

### Sinks

An admin sends each entry to a **sink** as it is written, in Console ▸ Audit ▸ Sinks on the
web page (#1001). Up to 4 sinks:

- **Syslog:** `tcp://host:port` or `tls://host:port`. Each entry is an RFC 5424 message
  (facility 13, log audit; severity 6; app `agents-control`; the copy's id as its process;
  message id `audit`), framed by its length as RFC 6587 says.
- **HTTP:** an `https://` address (`http://` only on the same machine). Each POST carries up
  to 500 entries as JSON lines (`application/x-ndjson`), with an optional bearer token.
  The control plane keeps the token sealed, as it keeps an org route's key, and never shows
  it again: leave it empty to keep it.

Each line is `{"key": …, "hash": …, "entry": …}`: the entry, its key in the store, and the
hash it has in its chain, so the SIEM can follow each chain by itself. Each copy of the
control plane sends the entries it writes. Each sink has a queue of 10,000 entries: when a
sink is down, entries wait there and go when it is back. When the queue is full, the oldest
go, and the next line says how many (`"dropped": N`). The pane shows, for each sink, when it
last sent, how many wait, how many were dropped and the last failure.

The methods are `audit/sinks` and `audit/setSinks`, an admin's only. The sinks are kept in
the store under `v1/audit-sinks.json`.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Hand files to a workflow](../how-to/hand-files-to-a-workflow.md)
- [Set up a workflow](../how-to/set-up-a-workflow.md)
- [Workflow triggers and actions](workflows.md)
- [Tools the app gives agents](agent-tools.md)
- [Statuses and groups](statuses.md)
