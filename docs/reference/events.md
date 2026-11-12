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
  - `request` and `kind` on `request.opened`, `request.deferred`, `request.answered` and
    `request.dropped`: a request's id, or `decide`, `secret` or `step` (#3863);
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
  "outcome" is not one of its arguments. To wait for particular agents, use agent.ended with agent.* A workflow file with one is unreadable, and says so, rather than firing for
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
another folder's events. To wait for particular sessions, it waits on `agent.ended` with `agent`, which reaches every
session of the project, on every machine. To
resume at a time, it waits on `time.reached` alone, with `until_minutes` (#4843). It is a
marker, not an event: nothing raises it on the bus, so the wait ends at its deadline and
the agent is told the time has come. A list with `time.reached` and other events is
refused, since every wait already ends at its deadline, and a workflow trigger refuses it:
a schedule runs at a time.

## Agents

All are about agents in the same folder. Only `agent.ended` takes a filter: `agent`, the
sessions to wait for (#3799). Each shows:

- `agent`, the agent's id;
- `labels`, the agent's labels;
- `runtime`, its runtime: `claude`, `codex`, `grok` and the others this version knows;
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
| `agent.ended` | agent | agent, how | An agent ended: it finished its turn, was stopped, or failed. `how` is `done`, `nothing_to_do`, `needs_answer`, `stopped` or `failed`; a turn that ends waiting is not raised. A wait on it names the sessions in `agent`, by id or exact title, or sets `any: true`, and waits on it alone; it reaches every session of the project, on every machine, and wakes when all have ended or, with `wake_on: any`, at the first. One that has already ended answers at once. See [Wait for sessions](../how-to/wait-for-something.md#wait-for-sessions). |
| `agent.archive_requested` | — | agent, outcome | An agent's turn ended after `archive_session`, and its session waits for you to approve archiving it. `outcome` is its last report's, when it made one. |
| `agent.messaged` | — | agent, from, from_title | An agent was sent a message by another agent with `message_session`. `agent` is the one it was sent to; `from` is the sender's id and `from_title` its title. |
| `agent.background_ended` | — | agent, commands, count, after_restart | The background commands an agent left running after its turn all ended (#4577): a dev server, a build or a watcher that its runtime runs in a process group of its own, or a terminal it asked for. `commands` names them (at most four), `count` says how many. Only that agent's own wait wakes on it, so an agent that ends its turn on a background build waits with `wait_for_event` on `agent.background_ended` and is started again when it ends. Looked at every 30 s. Not raised for processes that end within a turn, nor on Claude, which starts itself again when its command ends; a wait on it there, or with nothing running in the background, is refused. After an Agents restart the processes that outlived their runtime are watched again, and the event has `after_restart` `true`; a Claude session with no wait open is then sent a prompt, as its runtime would have started itself. |
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
| `branch.moved` | branch, any | branch, from, to | A branch an agent works on moved; never the default branch. A wait names the branch or sets `any: true` (#3797). |

## Files

`file.added` and `file.removed` are about files in the folder (#3795). A wait or a trigger
on them names the files it watches in `paths`: a list of globs relative to the folder,
such as `reports/*.csv`. `*` stays in one folder; `**` reaches into folders, as in
`docs/**/*.md`. A wait or a trigger without `paths` is refused, and so is a glob that starts
with `/` or goes up with `..`.

Each folder's drop box, the folder `.agents/dropbox/` in it, has no event of its own
(#3796): a file put there is a `file.added`, which a wait or a trigger watches with paths
such as `.agents/dropbox/review/**`. See [Hand files to a workflow](../how-to/hand-files-to-a-workflow.md).

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `file.added` | paths (required) | paths, count | Files the globs match appeared: made, copied, pulled or moved in. |
| `file.removed` | paths (required) | paths, count | Files the globs match went: deleted or moved away. |

- **Only watched paths.** The daemon keeps the globs of the running waits and the turned-on
  workflow triggers of each folder. A change to a file that no glob matches is dropped
  before anything is written to the event log, so a folder with no such wait or trigger
  writes nothing.
- **Added and removed only.** A move is both: the old path is removed and the new one is
  added. A file written over under the same name raises nothing. A file still being
  written is added once, after it stays as it is for 600 ms.
- **One event for many files.** Every file that comes (or goes) in one look is one event.
  `paths` is a JSON list of them, relative to the folder, sorted, at most 100; `count` is
  how many there were. A wait matches when one of the listed paths matches one of its
  globs.
- **Left out.** The files the folder's watch leaves out: `.git`, `.agents/worktrees` and
  build output (`node_modules`, `.build`, `build`, `DerivedData`, `target`, `dist`).
  `.gitignore` is not read: the glob says which files matter.
- **From when it watches.** The files there when a wait starts, or when a workflow is read
  or turned on, are not added.
- **This machine.** A file event stays on the machine whose folder it is.

## This Mac

These belong to the machine the host runs on, not to a folder. Any agent can wait for them.

`mac.sleep`, `mac.wake`, `person.away` and `person.back` are raised only on a Mac: a Linux
server has nothing that hears them. On a server, a `wait_for_event` naming only these is
refused, one naming them with others says so in its answer, and `manage_workflows` says so
when it writes or lists a workflow that triggers on them. The disk and capacity events fire on both, so
they are `machine.`.

| Event | Filter by | Details | What it means |
| --- | --- | --- | --- |
| `lease.granted` | — | resource, agent | An agent was given a lease. See [Leases on shared resources](../explanation/leases.md). |
| `lease.released` | — | resource, how | A lease was given back, ended or ran out. `how` is `released`, `ended` or `expired`. |
| `mac.sleep` | — | | The Mac is going to sleep. Mac only. |
| `mac.wake` | — | | The Mac woke up. Mac only. |
| `machine.disk_low` | — | volume, free_bytes, free_percent, level, threshold, worktrees | Free space on a volume holding the Agents root, a folder or a worktree fell below its threshold. `level` is `low` (below 10% of the disk) or `critical` (below 1%, where commands start failing); Folder Settings ▸ Disk Space moves both. `threshold` is the line it fell below, in bytes. `worktrees` names the largest worktrees on the volume and their sizes, measured within a budget, so `over` means at least. Raised once per crossing; falling further from low to critical is a second crossing. The window shows a strip across the top while it lasts. On a Linux server the volume is called "This server’s disk". |
| `machine.disk_ok` | — | volume, free_bytes, free_percent, threshold | Free space on a volume that was low climbed back above its threshold, by a margin of a tenth of it (at least 1 GB) so it does not flap. |
| `machine.busy` | — | level, signal, load_per_core, memory_pressure, swap_used_percent | The machine is near or at capacity (#4578). `level` is `near` (load per core above 2.0) or `full` (load per core above 3.0, or memory pressure `critical`); `signal` is what put it there: `load` or `memory_pressure`. Memory pressure `warn` and swap are reported but give no level: on macOS both stay high when the machine is not busy (#4583). Load per core is the 1-minute load average over the cores; memory pressure is the kernel's (macOS `kern.memorystatus_vm_pressure_level`, Linux PSI). Looked at every 15 s. Raised as the level leaves `ok`, not when it goes from near to full. `machine/usage` carries the same signals and the level as `capacity`. |
| `machine.ok` | — | was, load_per_core, memory_pressure, swap_used_percent | The machine that was near or at capacity is `ok` again: every signal was under its line for two looks in a row, so it does not flap. `was` is `near` or `full`. |
| `person.away` | why | why | You locked the screen or stepped away for 5 minutes. `why` is `locked` or `idle`. Mac only. |
| `person.back` | why | why | You unlocked the screen or came back. `why` is `locked` or `idle`. Mac only. |
| `cost.limit_reached` | — | limit, agent | A spending limit was reached. When it is an agent's, it also carries `labels`, `runtime` and `started_by`. See [Settings and the Resources page](settings.md). |
| `cost.allowance_out` | — | runtime, until, retry_after, reason | A runtime's allowance ran out, its credit was used up, or it failed. `until` is the time the provider gave, when it gave one; `retry_after` is when the app next checks it. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| `cost.allowance_back` | — | runtime, how | A runtime is back: `check` (the app's check passed), `person` (Mark available), `worked` (a turn on it worked), `time` (a rate limit's wait passed) or `another host` (a server said so). |
| `account.read` | — | service, address, machine, agent | `manage_accounts` read an outside account: a `get`, or a `list` filtered to its service (#4157). A `list` with no service reads no account. Never a value of the account. |
| `account.changed` | — | service, address, machine, agent, change | `manage_accounts` added an account (`change` is `added`) or put one in another's place (`edited`). |
| `secret.read` | — | name, machine, agent, use, place | agentsd gave a session a secret (#4156). `use` is `fill` (`fill_secret`; `place` is the field's domain), `ci` (`set_ci_secret`; `owner/repo`), `mcp` (an HTTP MCP server's header or url, filled by agentsd on each request; the server's name) or `env` (given at the session's start: its own secrets as variables, `place` is `session`, and each MCP server's `${NAME}`, the server's name) or `command` (`agents-secret NAME`, #4178; `place` is `agents-secret`, or `terminal` with no agent for a call with no session's grant that a person allowed, #4179). Never the value or its hint. Every value is sealed in `~/.agents-secrets/sealed.json`, which only agentsd opens, so each read goes through agentsd and is recorded. |
| `secret.denied` | — | name, machine, agent, use, place | A person denied a use of a secret with Ask before use. |
| `secret.changed` | — | name, machine, change, agent | A secret was set (`change` is `added`), replaced (`replaced`) or removed (`removed`) on this machine: in Settings ▸ Secrets, by `ask_secret`, or as a session's own. `agent` is there for a session's own secret. |
| `server.offline` | — | server | A server's connection dropped. Raised once, while the Agents window is open. |
| `server.online` | — | server | A server that was offline is back. Raised once, while the Agents window is open. |
| `system.restarted` | — | reason, down_since, down_for, down_for_text | Agents started again, on a Mac or a server. `reason` is `stopped` (a clean stop was recorded), `crashed` (it was alive and never said it stopped) or `first_start` (nothing was recorded). `down_since` is when it stopped or was last alive; `down_for` is the gap in seconds and `down_for_text` in words ("3 min", or "unknown"). See [Restarts](#restarts). |

## Requests

What an agent asks a person for (#3863, spec 3862): an `ask_question`, `ask_secret` or
`hand_to_person`. The daemon keeps each one in `<root>/requests/<id>.json`, so a restart
does not lose it, and keeps an ended one for 14 days (at most 1,000 records). A session joins
a request with `wait_for_event` on `request.answered` and `request.dropped`, `where:
{request: <id>}`; every session that waits on it wakes when it ends. A session whose turn has
ended and that waits only on requests (or on a wait for the person) holds no running place.

A GitHub item that asks the person for something is a request too (#3865): an issue labelled
`alex-todo` (a step) or `needs-account` (an account), with its `## What Alex does` checklist,
and a pull request labelled `needs-approval` (an approval), with its `## Screenshots`. The
daemon sweeps every 5 minutes. Answered in the app, the answer goes to GitHub as the person: a
ticked line ticks the issue's line; the last one removes the label, unassigns the person and
says so in a comment; an approval posts the note and sets `approved` (or `changes-wanted`).
On a pull request that the agents' bot opened, the note is the person's real review of its
head commit, Approve or Request changes (#3860); on the person's own, which GitHub does not
let them review, it is a comment.
A label changed on GitHub opens or ends the request at the next sweep. A lane waits on its
approval with `where: {pr: <n>}`; the answer is `approve: <note>` or `changes: <note>`.

A person can put an open request off to **Later** (#4233): `requests/defer` with `until` (a
time after now), `atMac` (when the person is next at the Mac) or both, whichever comes first;
`requests/undefer` brings it back now. A deferred request stays open, and its waiters keep
waiting and are not woken; but it is no need, so it sends no banner and no push, and is in no
count, until it comes back. `atMac` is the Mac's presence changing from not here to here
(a report of activity within 120 s): one deferred while the person is at the Mac comes back
the next time they return to it. When it comes back, `request.opened` is raised again and it
alerts once, as a new request does. The deferral is kept in the record, so a restart keeps it;
an answer or a drop clears it.

| Event | Filter by | Details | Meaning |
|---|---|---|---|
| `request.opened` | request, kind, pr, issue | request, kind, source, title, agent, pr or issue, url | An agent in this folder asked a person for something. |
| `request.deferred` | request, kind, pr, issue | request, kind, source, title, agent, pr or issue, url, until, atMac | A person put a request off to Later. `until` is RFC 3339; `atMac` is `true`. |
| `request.answered` | request, kind, pr, issue | request, kind, source, title, agent, pr or issue, url, answer, answered_by | A request was answered. `answer` is a summary, never a secret's value. |
| `request.dropped` | request, kind, pr, issue | request, kind, source, title, agent, pr or issue, url, why | A request ended with no answer. `why` is `askerEnded`, `folderArchived`, `forgeClosed`, `restarted` or `byPerson`. |

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

## The envelope

Every event, the app's own and every MCP server's, has the same envelope: the
[CloudEvents 1.0](https://cloudevents.io) JSON format, with two extensions, `provider` and
`topic` (#4728, spec `specs/4724-event-bus/spec.md`). `events/list` returns it, and
`events.jsonl` keeps it.

```json
{
  "specversion": "1.0",
  "id":       "github:pr:alexec/agents#4702@pr.commented/2457",
  "type":     "pr.commented",
  "provider": "github",
  "topic":    "alexec/agents",
  "subject":  "github:pr:alexec/agents#4702",
  "source":   "github:alexec/agents",
  "time":     "2026-11-11T17:02:11Z",
  "producer": "agents:machine:#mac-mini",
  "data":     { "number": 4702 }
}
```

| Field | What it is |
| --- | --- |
| `id` | The event's ref: the subject's ref, `@`, the type, and, when the same type can happen again to that thing, `/` and the provider's key for this one. It comes from the provider's data only, never from the machine or the clock, so two machines that hear the same happening make the same id. |
| `type` | The event's name, `noun.verbed`. |
| `provider` | Who it is about: `github`, `jira`, `slack` and so on; `agents` for the app's own. |
| `topic` | The provider's space, in lower case: a repo's full name, a Jira project, a Slack channel. |
| `subject` | The ref of the thing it happened to (`provider:type:topic#id`). |
| `source` | `provider:topic`. |
| `time` | When it happened, in RFC 3339: the provider's own time when it says one. |
| `producer` | The machine that raised it, as `agents:machine:#<machine>`. Not part of the id. |
| `data` | What it carries: an MCP server's event data, or the app's own event's details. |

- **The app's own events** have the provider `agents`. Their topic is the folder's project
  for `agent.*`, `workflow.*`, `request.*`, `branch.*`, `folder.*`, `file.*` and
  `cost.limit_reached`, and the machine for `machine.*`, `mac.*`, `person.*`, `lease.*`,
  `server.*`, `system.*` and `cost.allowance_*`. Their subject is the session
  (`agents:session:<project>#<agent>`), the workflow, the request, the branch, the folder,
  the lease (`agents:lease:<machine>#<resource>`), the server or the machine
  (`agents:machine:#<machine>`). Only the machine that raises one has it, so its key is the
  event's position on that machine.
- **An MCP server's event** takes its subject and key from the server, which says them in
  `events/poll` beside each event's `eventId`, as `subject` (a ref in the full form) and
  `key`. A server that says none, or a subject that is not a ref, gets the provider
  `server:<name>`, no topic and no subject, and its `eventId` as the key:
  `server:ci@build.done/evt-9`. The subjects and keys of this folder's servers are in
  [Subjects and keys](#subjects-and-keys).
- **The details stay for one release.** `name`, `details`, `position`, `scope` and the rest
  are still there, so a reader of the old shape works. An event recorded before the
  envelope gets one when the log is read, with no subject for a server's event.

## The bus

Every machine puts the events it records on its person's bus, on the control plane (#4729,
spec `specs/4724-event-bus/spec.md`, "The bus"). The Mac download runs the same code on the
Mac's own control plane.

- **Publish.** About a second after an event is new, the machine sends its envelope
  (`bus/publish`, at most 100 at a time): the id, type, provider, topic, subject, source,
  time and producer. Never the details, and never `data` in clear: the control plane reads
  only refs, names and times.
- **Sealed data (#4825).** The machine seals `data` (at most 256 KB) with HPKE to each other
  machine of its person's lock, to the sealing key the lock names, with its own signature
  inside (`sealed` on `BusEvent`). The control plane keeps the copies in the bus log, gives
  each machine its own copy only, and opens none; it cannot make one up, as a machine takes
  data only signed by a machine of its lock. A machine opens its copy and records it as the
  event's `data`. A machine that joined after the event, a machine with no lock, and data
  over 256 KB get the envelope only.
- **Dedupe.** The control plane keeps the first copy of each `id` and drops a later one,
  from any machine, with a create-if-absent write in its store, so several copies of the
  control plane agree. It counts what it drops (`agents_control_bus_events_total`, by
  `result`: `kept`, `dropped`, `delivered`).
- **The bus log** is the last 100,000 envelopes (with their sealed data) of each person's bus,
  for dedupe and the Events page; the hourly sweep deletes the older ones. A person's client
  reads it with `bus/log` (#4732): envelopes only, without the sealed data, newest first, at
  most 500 at a time (100 by default), narrowed by `provider`, `type` (a name or `noun.*`)
  and `topic`; `next` is where the next page back starts (`before`). It reads at most 2,000
  envelopes per call, so a narrow filter can answer with few events and a `next`.
- **Deliver.** A machine says its subscriptions (`bus/subscribe`: `provider`, `type`, a name
  or `noun.*`, `topics` and `subject`) to the copy that holds it, again after each connect
  and a short time after each change. `wait_for_event` and a workflow's `on:` make them
  ([Subscribe by provider, topic and subject](#subscribe-by-provider-topic-and-subject)).
  A new event goes at once (`bus/deliver`) to each other machine of the person with a
  subscription that matches it. That machine records it in its own log once (an id it
  already has is dropped) and never publishes it again.
- **Producer leases (#4731).** Only one of a person's machines polls each server's poll: a
  folder's project, the server's name, the event and its filters, hashed (`poll` on the
  envelope), so the same on every machine. Before each poll the machine asks for the poll's
  lease, or renews it (`bus/lease`); the lease lasts 5 minutes from the last renewal. The
  holder polls; another machine stands by: it does not poll, and the control plane delivers
  it each event of that poll, which it records as its own subscription's, so its waits wake.
  The holder lets its leases go when its Mac goes to sleep, a subscription ends or stops, or
  agentsd stops, so another machine takes over at its next poll (10 seconds to 5 minutes);
  one that goes offline loses them after 5 minutes. A machine that takes over polls from
  now: what happened in between is missed. A folder with no project, or a control plane
  without `events.leases/1`, has no lease. Until the bus carries `data` (#4825), only a
  subscription that waits alone hold stands by: one that a workflow or Archive when merged
  holds needs the event's data, so it always polls, and takes the lease when it is free.
- **Best effort.** Usually once, sometimes never, rarely twice. There is no resend and no
  backfill: an event sent while the control link is down is not sent later, and a machine
  that is not connected misses what is delivered meanwhile. A consumer treats an event as
  a hint and reads the subject's state now.

## Subscribe by provider, topic and subject

`wait_for_event` and a workflow's `on:` take four keys beside the type (#4730):

| Key | Value | What it does |
| --- | --- | --- |
| `provider` | One provider: `github`, `gitlab`, `jira`, `linear`, `slack`, `agents` and so on | Only events of that provider. |
| `topic` | One topic, or a list (any of them) | Only events about that topic: a repo's full name, a Jira project, a Slack channel ([Topics](#the-envelope)). Lower case. |
| `subject` | A ref, in the full form, such as `github:pr:alexec/agents#4702` | Only events about that one thing. The plain way to say "this pull request" on any machine. |
| `debounce` | A time from `1s` to `1h`, such as `30s` or `2m`, or a number of seconds | A burst of matching events on one subject and type is held that long from the first, and delivered once: the last one, with how many came. |

- **The bus.** A wait or a trigger with `provider`, `topic` or `subject` matches on the
  event's envelope, and also hears the events of the person's other machines: the machine
  sends it as a subscription on [the bus](#the-bus). An event made on machine B wakes a
  session on machine A.
- **A bare type means what it means now.** With none of the three, `pr.merged` hears this
  folder's servers and the app, on this machine only. `server:` still names one MCP server
  by its `mcp.json` name.
- **`where` and the bus.** An event from another machine has its envelope only, so a wait
  or a trigger that has `where` (a server's or the app's own keys, such as `pr: 4702`) is
  not woken by one: name the thing in `subject` instead. On its own machine `where` works
  as before.
- **A forge's server here** is asked for what `subject` and `topic` name when `where` does
  not: `subject: github:pr:alexec/agents#4702` subscribes this folder's GitHub server with
  `repo: alexec/agents` and `pr: 4702`. A server here that cannot give the event is said
  in the wait's answer, not refused: the wait then hears other machines only.
- **Debounce is best effort.** It is done on the machine that has the wait or the workflow,
  so it covers that machine's own events too. A restart drops what it holds.
- **`type`** is the word in the tools and the workflow files. `name` is read the same way
  for one release.
- **Every event says its ref.** A woken agent's message and a workflow agent's prompt say
  the event's ref (`id`) and its subject, and that it is a hint: read the subject's state
  now before acting on it, and make doing it twice harmless. A wait that times out says to
  check the state now rather than take no event as nothing happened.

```yaml
on:
  - type: pr.merged
    provider: github
    topic: alexec/agents
  - type: issue.created
    provider: jira
    topic: abc
    debounce: 30s
```

## No custom events

Agents do not raise events of their own. The `publish_event` tool and the `custom.` events it
raised were removed (#639). A wait on a `custom.` name is refused, saying why, and a workflow
whose `on:` names one does not run: its page says what is wrong. To wait for another agent,
wait on `agent.ended` with `agent`. A `custom.` event already on the log still shows, with the
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
- **One `where` for several events.** When a wait names several of a server's events, each
  event gets only the keys it takes. So `issue.closed` gets `issue` and `pr.merged` gets
  `fixes`, in one wait. A key that none of them takes is refused. A key that two of them
  take goes to both: `branch` on `pr.merged` means a PR *from* that branch.
- **It names what it waits for** (#3797). This applies to a wait on an event about one
  thing, on a server whose event takes `any`: today the `github`, `forgejo`, `gitlab`,
  `bitbucket`, `azuredevops` and `azureboards` servers (#3821). The wait names the thing, or it sets `any: true` to wake on every one. A wait
  that does neither is refused, with the words that say what to set: *github's pr.merged:
  Name the PR (`pr`, `branch`, `fixes` or `mine`), or set `any: true` to wake on every PR
  in the repo.* `any` is about *which* ones. It is not `anyone`, which is about *who*.
  Workflow triggers are not checked: a trigger on every merge is the usual trigger, and a
  person reads it in its file.

  | Event | Names it with | `any: true` |
  | --- | --- | --- |
  | `pr.merged`, `pr.closed`, `pr.conflicted`, `pr.commented`, `pr.reviewed`, `pr.labelled`, `pr.unlabelled`, `review.posted`, `review.comment` | `pr`, `branch`, `fixes` or `mine` | yes |
  | `checks.failed`, `checks.passed` | `pr`, `branch`, `fixes` or `mine` | yes |
  | `run.completed` | `run`, `branch`, `workflow` or `pipeline` (Azure DevOps) | yes |
  | `issue.closed`, `issue.commented`, `issue.labelled` | `issue` or `label` | yes |
  | `branch.moved` (the app's) | `branch` | yes |

  `pr.opened` and `issue.opened` are not checked, because a wait on a new one cannot name
  it. `issue.assigned` and `review.requested` are not checked, because they are only the
  connected account's. Only the keys that a server offers are named: GitHub's
  `pr.commented` has no `branch`. `fixes` is a list of issues, `"#12"` (the repo's own) or
  `"owner/repo#12"` (`"group/project#12"` on GitLab, `"workspace/name#12"` on Bitbucket,
  only `"#12"`, a work item, on Azure DevOps). It matches a PR whose body closes one of
  them, so a lead can wait on a child's PR before the PR exists. `issue` takes one number
  or a list (on Azure Boards, a work item's id as a string, `"12"`, or a list of them).
  `mine` is the connected account's own PRs, merged or closed ones too. Every PR's payload
  carries its `fixes`.
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

### Subjects and keys

What each of this folder's MCP servers says of its events' envelope (#4728). The topic is
in lower case; the id keeps its case. "Poll time" is for an event about a state (in
conflict, opened, assigned) that has no time or id of its own: its key is when the poll saw
it, so two machines can make two ids for one change.

| Server | Events | Subject | Key |
| --- | --- | --- | --- |
| `github` | `issue.*` | `github:issue:<owner/repo>#<n>` | the activity's id |
| `github` | `pr.labelled`, `pr.unlabelled`, `pr.commented`, `pr.reviewed`, `review.comment` | `github:pr:<owner/repo>#<n>` | the label activity's, comment's or review's id |
| `github` | `checks.failed`, `checks.passed` | the run's PR, or the run (`github:run:…#<run id>`) when it names none | the head commit, or the run's attempt |
| `github` | `run.completed`, `deploy.waiting` | `github:run:<owner/repo>#<run id>` | the attempt (and the environments) |
| `github` | `pr.merged` / `pr.closed` | the PR | none / the close time |
| `github` | `pr.conflicted` and the other states | the PR, or the issue for `issue.assigned` | the review for `review.posted`, else the poll time |
| `gitlab` | `issue.*`, `review.comment`, `pr.merged`, `pr.closed`, states | `gitlab:issue:` or `gitlab:mr:<group/project>#<n>` | as `github` |
| `gitlab` | `checks.failed` | `gitlab:pipeline:<group/project>#<pipeline id>` | the pipeline's update time |
| `gitlab` | `run.completed`, `deploy.waiting` | `gitlab:pipeline:<group/project>#<pipeline id>` | the update time, or the blocked deployments |
| `forgejo`, `bitbucket` | `issue.*`, `review.comment`, `pr.merged`, `pr.closed`, states | `<server>:issue:` or `<server>:pr:<owner/repo>#<n>` | as `github` |
| `forgejo`, `bitbucket` | `checks.failed` | the PR | the head commit and the time |
| `bitbucket` | `run.completed` | `bitbucket:run:<workspace/name>#<build number>` | the finish time |
| `forgejo` | `run.completed` | `forgejo:run:<owner/repo>#<run number>` | the finish time |
| `azuredevops` | PR events, `checks.*` | `azuredevops:pr:<org/project/repo>#<n>` | the thread and comment, or the head commit and the time |
| `azuredevops` | `run.completed`, `deploy.waiting` | `azuredevops:run:<org/project/repo>#<build id>` | the finish time, or the environments |
| `azureboards` | `issue.*` | `azureboards:issue:<org/project>#<id>` | none for `issue.opened`; else the activity's id |
| `jira` | `issue.*` | `jira:issue:<project>#<KEY-n>` | none for `issue.opened`; else the comment, label or change's id |
| `linear` | `issue.*` | `linear:issue:<team>#<ENG-n>` | none for `issue.opened`; else the comment, label or history entry's id |
| `sentry` | `health.issue_new` / `health.issue_regressed` | `sentry:issue:<org/project>#<id>` | none / the regression's time |
| `betterstack` | `health.incident_*` | `betterstack:incident:<team>#<id>` | none |
| `slack` | `message.received`, `question.answered` | `slack:message:<team/channel>#<ts>` (the question's for an answer) | none |
| `googlechat` | message and answer events | `googlechat:message:spaces/<space>#<message>` | none |
| `whatsapp` | message and answer events | `whatsapp:message:<phone number id>#<wamid>` | none |
| `email` | `email.received` | `email:message:<mailbox>#<Message-ID>` | none |

## The Events page

On the Mac, **Events** is a row at the foot of the sidebar, above **Resources** and
**Spending**. It shows every event, newest first, grouped by day. It reads the person's
bus as well as this Mac's log (#4732): an event on the bus log that this Mac's log does not
have, another machine's, joins the list, by the time it happened. Such a row has no
folder here, so a folder's filter leaves it out. The bus log is read again every 30
seconds while the page is open.

- **Filters**: on one line, a menu for all folders, this Mac or one folder, and a menu each
  for the provider, the type and the topic, with every value the rows have (#4732); on
  the next line, a capsule for each subject: **Agents**, **Workflows**, **Branches**,
  **Drop box** and **This Mac**.
- **Each row** shows the time, what happened, and the event's type, provider, topic and
  where: its folder, This Mac, or **From** the machine that raised it. Under it, the
  event's ref; right-click a row for **Copy Ref**. Under that, what it led
  to: **Woke** an agent, **Fired** a workflow, **Refused by** a workflow with the reason,
  or **Could not wake** an agent with the reason. A repeat shows a count, such as ×4.
- **Click a row** to see every detail it carries. **Copy as trigger** copies it as a
  workflow's `on:` line, narrowed by the event's filters only: `branch` on a
  `branch.moved`, `why` on a `person.away` or `person.back`. Every other event is copied
  as its name alone. **Copy Ref** copies the event's ref; the detail also lists its ref,
  provider, topic and subject.
- **Waiting now**, at the top, lists every agent that is waiting for an event, what for
  and until when, with ✕ to end the wait. It is not shown when nobody is waiting.

The web page's Events (Status ▸ Events) does the same: every host's log and the bus log,
the provider, type and topic menus, the ref under each row, and **Copy ref** in a row's
sheet.

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
  the host when it opens the client's channel (`ChannelOpen.actor`). Once the client opens a
  checked channel (`lock/hello`), the host takes the client's id and name from its lock entry
  instead, and refuses the channel when the two ids differ (#3543).
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
- **An agent's reads and changes of an outside account** (#4157): `manage_accounts` tells the
  control plane of each, and it keeps "Listed accounts", "Added an account" or "Changed an
  account", with the account's service and address as the target and the machine's person as
  who did it. A `list` with no service is not kept.
- **An agent's reads of a secret, and its changes** (#4156): agentsd tells the control plane
  of each (`machine/secretOps`), and it keeps "Read a secret", "Denied a secret's use", "Added
  a secret", "Replaced a secret" or "Removed a secret", with the target `NAME · use · place`
  (`GITHUB_TOKEN · fill · github.com`) and the machine's person and the machine as who did it.
  Reads are kept at most once per secret, session, place and minute, with the count
  (`· 12 times`). A person's Set and Remove in Settings ▸ Secrets are their own entries ("Set a
  secret", "Removed a secret", `user/setSecret` and `user/removeSecret`). Never a value. Each
  machine also keeps each secret's last operation in `secret-ops.json`, for the names it holds,
  and a removed secret's goes with it. It sends that last operation, and the hint of each copy
  (the last 4 of a value of 16 characters or more, or of a card's number), with what it holds
  (`machine/secretOps`, `held`; #4158). The control plane keeps both in memory only and puts
  them on the person's own rows (`user/secretNames`: `hint`, `lastOp`, `created`,
  `backedUp`). The store never has a hint.
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
