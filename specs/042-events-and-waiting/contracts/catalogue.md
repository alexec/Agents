# Contract: the event catalogue

This is the single table `EventCatalogue.all` is built from (FR-003). The Source column says
where in the daemon each event is raised. The details are the keys each event carries, which are
also the keys a filter may use. Every event whose details include `agent` also carries
`agent_title`, which is used for display and is not a filter.

| Name | Scope | Details | Meaning (as `list` and `manage_workflows` say it) | Old name | Source |
|---|---|---|---|---|---|
| `agent.started` | project | agent | An agent in this project started working. | | start, the first turn |
| `agent.finished` | project | agent, outcome | An agent in this project ended a turn having done its work. | `agent-finished` | lifecycle funnel |
| `agent.asked_permission` | project | agent | An agent in this project is asking for permission. | `agent-asked-permission` | lifecycle funnel |
| `agent.asked_form` | project | agent | An agent in this project raised a form to fill in. | `agent-asked-form` | lifecycle funnel |
| `agent.blocked` | project | agent, waiting_on | An agent in this project ended its turn waiting on something. | | `finish_turn blocked`, `wait_for_event` |
| `agent.stopped` | project | agent, by | An agent in this project was stopped before finishing. | `agent-stopped` (with `failed`) | lifecycle funnel, where the reason is a person, an agent or the app |
| `agent.failed` | project | agent, reason | An agent in this project ended in an error. | `agent-stopped` (with `stopped`) | lifecycle funnel, where the reason is a process death or an error |
| `workflow.ran` | project | workflow, agent | A workflow in this project started an agent. | | `record(.ran)` |
| `workflow.completed` | project | workflow, agent | A workflow's run in this project finished. | `workflow-completed` (`id` → `workflow`) | `workflowRunFinished` |
| `workflow.refused` | project | workflow, reason | A workflow in this project did not run, and why. | | `record(.refused)` |
| `pull_request.opened` | project | number | One of my pull requests was opened. | | 038 refresh diff |
| `pull_request.checks_failed` | project | number | Checks started failing on one of my pull requests. | `pull-request-checks-failed` | diff |
| `pull_request.checks_passed` | project | number | Checks passed on one of my pull requests. | | diff |
| `pull_request.review_comments` | project | number | One of my pull requests got new review comments. | `pull-request-review-comments` | diff |
| `pull_request.approved` | project | number | One of my pull requests was approved. | | diff |
| `pull_request.changes_requested` | project | number | Changes were requested on one of my pull requests. | | diff |
| `pull_request.conflicts` | project | number | One of my pull requests conflicts with its base. | `pull-request-conflicts` | diff |
| `pull_request.merged` | project | number | One of my pull requests was merged. | | follow-up query |
| `pull_request.closed` | project | number | One of my pull requests was closed without merging. | | follow-up query |
| `pull_request.changed` | project | number, what | Anything above happened to one of my pull requests. | | alongside each of the above |
| `branch.moved` | project | branch, from, to | A branch moved: the default branch, or one an agent works on. | | `.git` watch |
| `lease.granted` | Mac | resource, agent | An agent was given a lease. | | `settle(.granted)` |
| `lease.released` | Mac | resource, how | A lease was given back, ended or ran out. | | `settle(.released)` |
| `mac.sleep` | Mac | | This Mac is going to sleep. | | IOKit will-sleep |
| `mac.wake` | Mac | | This Mac woke up. | | IOKit powered-on |
| `person.away` | Mac | why | You locked the screen or stepped away for 5 minutes. | | lock notification, HID idle |
| `person.back` | Mac | why | You unlocked the screen or came back. | | the same |
| `cost.limit_reached` | Mac or project | limit, agent? | A spending limit was reached. | | the limit checks, once per crossing |
| `server.offline` | Mac | server | A server went offline. | | 037's connection state, when 037 is on main |
| `server.online` | Mac | server | A server came back. | | the same |
| `custom.<name>` | project | publisher, message, and anything published | An agent in this project published this. | | `publish_event` |

`schedule` is a trigger and not an event. It stays exactly as it is.

## Subjects (the page's filter capsules)

| Capsule | Subjects |
|---|---|
| Agents | agent |
| Workflows | workflow |
| Pull requests | pull_request |
| Branches | branch |
| This Mac | mac, person, lease, cost, server |
| Custom | custom |
