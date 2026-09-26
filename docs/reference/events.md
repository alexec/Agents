---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every event the app records, what it carries, and where you can see them, wait for them and trigger on them.
---

# Events

An event is something that happened: an agent finished, a pull request's checks passed,
the Mac woke up. The app records each one. This page lists them all.

The same names work in three places:

- an agent's `wait_for_event` tool, to be started again when one happens (see
  [Have an agent wait for something](../how-to/wait-for-something.md)),
- a workflow's `on:`, to start an agent when one happens (see
  [Workflow triggers and actions](workflows.md)),
- the **Events** page, where you read what happened.

## Names and filters

A name is a subject, a dot, and what happened: `pull_request.merged`. A subject followed
by `.*`, such as `pull_request.*`, matches every event of that subject.

Each event carries details, listed in the tables below. A wait or a trigger can narrow an
event by its details, for example `number: 41` for one pull request. A detail the event
does not carry is an error: `pull_request.merged` takes `number`, not `branch`.

An agent can wait for its own project's events and for this Mac's. It cannot wait for
another project's events.

## Agents

All are about agents in the same project. Each carries `agent`, the agent's id.

| Event | Details | What it means |
| --- | --- | --- |
| `agent.started` | agent | An agent started working. |
| `agent.finished` | agent, outcome | An agent ended a turn having done its work. |
| `agent.asked_permission` | agent | An agent is asking for permission. |
| `agent.asked_form` | agent | An agent raised a form to fill in. |
| `agent.blocked` | agent, waiting_on | An agent ended its turn waiting on something. |
| `agent.stopped` | agent, by | An agent was stopped before finishing. |
| `agent.failed` | agent, reason | An agent ended in an error. |

## Workflows

| Event | Details | What it means |
| --- | --- | --- |
| `workflow.ran` | workflow, agent | A workflow started an agent. |
| `workflow.completed` | workflow, agent | A workflow's run finished. |
| `workflow.refused` | workflow, reason | A workflow did not run, and why. |

## Pull requests

All are about your open pull requests in the project's GitHub repository, and carry
`number`. The app learns of them when it refreshes the project's pull requests, so they
arrive a little after they happen on GitHub. See
[Have an agent watch a pull request](../how-to/watch-a-pull-request.md) for what the app
needs to see them.

| Event | Details | What it means |
| --- | --- | --- |
| `pull_request.opened` | number | One of your pull requests was opened. |
| `pull_request.checks_failed` | number | Checks started failing. |
| `pull_request.checks_passed` | number | Checks passed. |
| `pull_request.review_comments` | number | It got new review comments. |
| `pull_request.approved` | number | It was approved. |
| `pull_request.changes_requested` | number | Changes were requested. |
| `pull_request.conflicts` | number | It conflicts with its base branch. |
| `pull_request.merged` | number | It was merged. |
| `pull_request.closed` | number | It was closed without merging. |
| `pull_request.changed` | number, what | Any of the above happened to it. |

## Branches

| Event | Details | What it means |
| --- | --- | --- |
| `branch.moved` | branch, from, to | A branch moved: the default branch, or one an agent works on. |

## This Mac

These belong to the Mac, not to a project. Any agent can wait for them.

| Event | Details | What it means |
| --- | --- | --- |
| `lease.granted` | resource, agent | An agent was given a lease. See [Leases on shared resources](../explanation/leases.md). |
| `lease.released` | resource, how | A lease was given back, ended or ran out. |
| `mac.sleep` | | The Mac is going to sleep. |
| `mac.wake` | | The Mac woke up. |
| `person.away` | why | You locked the screen or stepped away for 5 minutes. |
| `person.back` | why | You unlocked the screen or came back. |
| `cost.limit_reached` | limit, agent | A spending limit was reached. See [Settings](settings.md). |
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
| `pull-request-checks-failed` | `pull_request.checks_failed` |
| `pull-request-review-comments` | `pull_request.review_comments` |
| `pull-request-conflicts` | `pull_request.conflicts` |

## The Events page

On the Mac, **Events** is a row at the foot of the sidebar, above **Resources** and
**Spending**. It shows every event, newest first, grouped by day.

- **Filters**: a menu for all projects, this Mac or one project, and a capsule for each
  subject: **Agents**, **Workflows**, **Pull requests**, **Branches**, **This Mac** and
  **Custom**.
- **Each row** shows the time, what happened, and the event's name. Under it, what it led
  to: **Woke** an agent, **Fired** a workflow, **Refused by** a workflow with the reason,
  or **Could not wake** an agent with the reason. A repeat shows a count, such as ×4.
- **Click a row** to see every detail it carries. **Copy as trigger** copies it as a
  workflow's `on:` line, with its details as filters.
- **Waiting now**, at the top, lists every agent that is waiting for an event, what for
  and until when, with ✕ to end the wait. It is not shown when nobody is waiting.

On the iPhone and iPad, **Events** is a row under the project list. It shows the same rows
and details, filtered by one menu. It has no subject capsules, no **Copy as trigger** and
no **Waiting now**.

## See also

- [Have an agent wait for something](../how-to/wait-for-something.md)
- [Workflow triggers and actions](workflows.md)
- [Tools the app gives agents](agent-tools.md)
