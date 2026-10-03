---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every event the app records, what it carries, and where you can see them, wait for them and trigger on them.
---

# Events

An event is something that happened: an agent finished, a branch moved, the Mac woke up. The app records each one. This page lists them all.

The same names work in three places:

- an agent's `wait_for_event` tool, to be started again when one happens (see
  [Have an agent wait for something](../how-to/wait-for-something.md)),
- a workflow's `on:`, to start an agent when one happens (see
  [Workflow triggers and actions](workflows.md)),
- the **Events** page, where you read what happened.

## Names and filters

A name is a subject, a dot, and what happened: `workflow.completed`. A subject followed
by `.*`, such as `agent.*`, matches every event of that subject.

Each event carries details, listed in the tables below. A wait or a trigger can narrow an
event by its details, for example `branch: main` for one branch.

- **A list means any of them.** `outcome: [done, nothing_to_do]` matches either. A list of one
  is the same as the value on its own.
- **`labels` is a set.** `labels: bug` matches an agent that has the label `bug` among
  others, compared as labels are, so `Bug` matches `bug`. `labels: [bug, regression]`
  matches an agent with either.
- **A detail the event does not carry is an error**, naming the ones it does: `branch.moved`
  takes `branch`, `from` and `to`, not `number`.
- **A wrong value is an error too**, for a detail with a fixed set of values, and the error
  names the right ones: *outcome on agent.finished is one of done, nothing_to_do,
  needs_answer, partly_done, stuck, blocked; "complete" is not one of them.* Details with
  open values, such as `labels`, `workflow`, `branch` and everything on a custom event, take
  any value.
- **Older words still match.** Before codes, `reason` and `by` held sentences, such as
  `reason: "its allowance ran out"`. A wait or trigger written that way is read as the code,
  here `allowance_spent`.

An agent can wait for its own project's events and for this Mac's. It cannot wait for
another project's events.

## Agents

All are about agents in the same project. Each carries:

- `agent`, the agent's id;
- `labels`, the agent's labels;
- `runtime`, its runtime: `claude`, `codex`, `gemini`, `grok` and the others this version knows;
- `started_by`: `person` (you, on the Mac, the phone or the web page), `workflow` (a workflow
  started it or resumes it), or `agent` (another agent started it as its helper).

These describe the agent as it was when the event happened. A label added later doesn't change
an event already on the log.

| Event | Details | What it means |
| --- | --- | --- |
| `agent.started` | agent | An agent started working. |
| `agent.finished` | agent, outcome, afterwards | An agent ended a turn having done its work. `afterwards` is `park` when the agent is parked once the turn is over (it asked to be, or you parked it while it worked), else `stay`. `outcome` is `done`, `nothing_to_do`, `needs_answer`, `partly_done`, `stuck` or `blocked`. |
| `agent.asked_permission` | agent | An agent is asking for permission. |
| `agent.asked_form` | agent | An agent raised a form to fill in. |
| `agent.blocked` | agent, waiting_on | An agent ended its turn waiting on something. When `waiting_on` names agents or a time to check again, the agent resumes by itself; otherwise it needs you to carry it on. See [Statuses and groups](statuses.md). |
| `agent.stopped` | agent, by | An agent was stopped before finishing. `by` is `you`, `cost_limit` or `unknown`. |
| `agent.failed` | agent, reason | An agent ended in an error. `reason` is `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `max_turn_requests`, `refusal`, `daemon_gone`, `stopped_by_agent` or `unrecognised`. |
| `agent.parked` | agent, outcome | An agent was parked: put down to come back to. `outcome` is its last report's, when it made one. |
| `agent.archived` | agent, by, outcome | An agent was archived. `by` is `you`, or `agent` when the agent that started it archived it with `archive_agent`. `outcome` is its last report's, when it made one. |
| `agent.retired` | agent, because | An archived agent was retired and its conversation deleted. `because` is `age`, `cap` or `person`. |

## Workflows

| Event | Details | What it means |
| --- | --- | --- |
| `workflow.ran` | workflow, agent | A workflow started an agent. |
| `workflow.completed` | workflow, agent, outcome | A workflow's run finished. `outcome` is its agent's report's, when it made one. |
| `workflow.refused` | workflow, reason | A workflow did not run, and why. `reason` is `run_in_flight`, `chain_too_deep`, `archived`, `over_limit`, `unreadable`, `trigger_not_supported`, `agent_unavailable`, `no_triggering_agent`, `missed_while_closed`, `folder_gone`, `day_limit_reached`, `setting_refused` or `awaiting_approval`. |

## Branches

| Event | Details | What it means |
| --- | --- | --- |
| `branch.moved` | branch, from, to | A branch moved: the default branch, or one an agent works on. |

## This Mac

These belong to the Mac, not to a project. Any agent can wait for them.

| Event | Details | What it means |
| --- | --- | --- |
| `lease.granted` | resource, agent | An agent was given a lease. See [Leases on shared resources](../explanation/leases.md). |
| `lease.released` | resource, how | A lease was given back, ended or ran out. `how` is `released`, `ended` or `expired`. |
| `mac.sleep` | | The Mac is going to sleep. |
| `mac.wake` | | The Mac woke up. |
| `person.away` | why | You locked the screen or stepped away for 5 minutes. `why` is `locked` or `idle`. |
| `person.back` | why | You unlocked the screen or came back. `why` is `locked` or `idle`. |
| `cost.limit_reached` | limit, agent | A spending limit was reached. When it is an agent's, it also carries `labels`, `runtime` and `started_by`. See [Settings and the Resources page](settings.md). |
| `cost.allowance_out` | runtime, until, retry_after, reason | A runtime's allowance ran out, its credit was used up, or it failed. `until` is the time the provider gave, when it gave one; `retry_after` is when the app next checks it. See [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md). |
| `cost.allowance_back` | runtime, how | A runtime is back: `check` (the app's check passed), `person` (Mark available), `worked` (a turn on it worked), `time` (a rate limit's wait passed) or `another host` (a server said so). |
| `server.offline` | server | A server's connection dropped. Raised once, while the Agents window is open. |
| `server.online` | server | A server that was offline is back. Raised once, while the Agents window is open. |

## Custom events

An agent can publish an event of its own with its `publish_event` tool, to tell other
agents and workflows in the same project that something happened.

- The name is `custom.` followed by up to 40 lowercase letters, digits and `_`, such as
  `custom.build_green` or `custom.release_ready`.
- It carries `publisher` and `message`, a short note of up to 500 characters for whoever
  wakes on it, plus up to 10 details of the publisher's own, which waits and triggers can
  narrow by.
- Each agent can publish at most 30 an hour.
- Only `custom.` events can be published. The others are raised by the app.

The publishing agent is told who was woken and which workflows ran.

## Older trigger names

Workflows written before events keep working. Each older name answers to these events:

| Older trigger | Events |
| --- | --- |
| `agent-finished` | `agent.finished` |
| `agent-asked-permission` | `agent.asked_permission` |
| `agent-asked-form` | `agent.asked_form` |
| `agent-stopped` | `agent.stopped`, `agent.failed` |
| `workflow-completed` | `workflow.completed` |

## The Events page

On the Mac, **Events** is a row at the foot of the sidebar, above **Resources** and
**Spending**. It shows every event, newest first, grouped by day.

- **Filters**: a menu for all projects, this Mac or one project, and a capsule for each
  subject: **Agents**, **Workflows**, **Branches**, **This Mac** and
  **Custom**.
- **Each row** shows the time, what happened, and the event's name. Under it, what it led
  to: **Woke** an agent, **Fired** a workflow, **Refused by** a workflow with the reason,
  or **Could not wake** an agent with the reason. A repeat shows a count, such as ×4.
- **Click a row** to see every detail it carries. **Copy as trigger** copies it as a
  workflow's `on:` line, with the event's own details as filters. It leaves out `agent`
  and the agent's `labels`, `runtime` and `started_by`, so the trigger fires for events
  like this one, not only for this agent. A custom event's details are all copied.
- **Waiting now**, at the top, lists every agent that is waiting for an event, what for
  and until when, with ✕ to end the wait. It is not shown when nobody is waiting.

On the iPhone and iPad, **Events** is a row under the project list. It shows the same rows
and details, filtered by one menu. It has no subject capsules, no **Copy as trigger** and
no **Waiting now**.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Set up a workflow](../how-to/set-up-a-workflow.md)
- [Workflow triggers and actions](workflows.md)
- [Tools the app gives agents](agent-tools.md)
- [Statuses and groups](statuses.md)
