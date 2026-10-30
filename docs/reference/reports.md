---
diataxis: reference
devices: [mac, iphone, ipad]
description: Usage, cost and time by person, project, folder, machine and runtime, added up on the control plane from what each machine sends.
---

# Reports

A report shows the usage, cost and time of each person, project, folder, machine and
runtime (#1811). The control plane adds them up from what each machine sends.

## The Reports pane

The Cost page has two panes, **Cost** and **Reports**, on the Mac, the Remote and the web
page.

- **The range:** D (the last 24 hours, by the hour), W, M or 3M (the last 7, 30 or 90
  days, by the day), as the Cost page's charts.
- **By:** Person, Project, Folder, Machine or Runtime. The first line is the total. Under it
  is a line for each person, project, folder, machine or runtime, largest first, with a bar
  for its share of the largest. Each line says the cost, the tokens, the turns and the
  working time. A segmented control on the Mac and the web page, and a menu on the Remote.
- **Project** (#2670) adds up the folders of one [project](../explanation/folders-machines-worktrees.md)
  on every machine. The control plane finds each row's project from the folders that its
  machine last reported (`projects/joined`). A row's folder is in **No project** when its
  machine reported no project for it, or when two of that machine's folders have the same
  name and are in different projects.
- **Export** saves the rows of the range as CSV or as JSON lines. Each row has its
  project's id and name.
- **Page** (the Mac and the Remote, #2183): Spend, or Outcomes, Time, Runtimes, Adoption or
  Workflows, which are the web page's Reports pages below at the Me scope. A segmented control
  on the Mac, and a menu on the Remote. On the web page these pages are in Reports. Value
  (#2351) is on the Mac only, not on the Remote (tier Mac + web, #2796).
- **A control plane that keeps no reports** (one from before #1811) says so, and says to
  update it.

## Reports ▸ Spend, on the web page

Reports is one of the control plane's three apps on the web page, beside Workspace and the
[Console](console.md) (#1804). Its page **Spend** is the Reports pane with a scope:

- **Me:** your own machines, as the Cost page's Reports pane on all three clients.
- **A group:** each group you lead, or every group for an admin. A lead sees each person,
  or with Totals Only no person and no machine named. **By** also has Group.
- **The organisation:** everyone, for an admin only.
- **A budget:** when the scope has one (Console ▸ Report Policy), the page shows the spend
  of this calendar month (UTC) against it, with a forecast to the end of the month. The
  control plane adds up the month (`monthSpentUSD`, #2057).
- **CSV** names each person's groups.

The Mac and the Remote show the Me scope only, also of the pages below (#2183).

## Reports ▸ Outcomes and Time, on the web page

Two more pages of Reports (#2019), with the same scopes, ranges and **By** as Spend:

- **Outcomes** (R2): what the agents shipped. Each line says the pull and merge requests
  merged of those opened, the reverts, the cost of each merged one, the mean time from the
  agent's start to the merge, and the sessions. The largest number merged comes first.
- **Time** (R3): where the agents' time goes. Each line says the share of the time the
  agents waited for a person, the waits and the length of the middle one, and the time
  working. The most waiting comes first.
- **A pull or merge request counts** when an agent made it on its own branch (a worktree's
  branch) and the machine heard of it: a workflow or a wait on `pr.opened` or `pr.merged`
  from the GitHub or GitLab server. Thus two machines that hear the same repository count it
  once, and a person's own pull requests do not count. A revert is one whose title starts
  with "Revert".
- **A wait** is a question, a form or a permission that waits for its person in a turn. It
  counts once, in the hour it began, by its whole length: under 1 minute, 1 to 5, 5 to 15,
  15 to 60, 1 to 4 hours, or longer. The middle wait is the bucket it falls in.
- **A machine from before #2019** sends no counts, so its rows count as nothing done.

## Reports ▸ Runtimes, Adoption and Workflows, on the web page

Three more pages of Reports (#2019), with the same scopes:

- **Runtimes** (R4): which runtime earns its cost. By Runtime first. Each line says the
  cost, the pull requests merged, the cost of each merged one, the sessions that failed
  and their share, and the turns not priced. The largest cost comes first. A session fails
  when it ends in an error that nobody chose (`agent.failed`).
- **Adoption** (R5): each week (Monday, UTC), newest first: the active people, the
  sessions a person, and the runtimes and workflows in use. A person is active in a week
  when one of their machines, or a bot's, ran a turn. With Totals Only, a lead sees the
  sessions, not the people.
- **Workflows** (R6): each workflow's runs (`workflow.ran`), its failed runs (its agent
  ended in an error), the cost of a run and the time working a run. By Workflow first. The
  most failed runs come first. By Person shows each bot's runs under its name.

## Reports ▸ Value, on the web page and the Mac (#2351)

What the work cost and what it delivered, from the cost on the links (#2350). The control
plane adds up the nodes that the scope's machines send (`v1/lineage/<host>.json`); the
machines' copies of one node add up, as each banked its own turns.

- **The headline:** the cost of the work on issues and pull requests, the PRs merged, and
  the cost per merged PR (that cost by the PRs merged, waste included).
- **Waste:** the PRs closed without a merge and the merged reverts, and the failed CI rounds.
- **Lead time:** the median of the issues' lead times, each from the first work on the issue
  or its PRs (`firstAt`) to its last PR merged (`endedAt`).
- **Unlinked:** the turns with no issue or PR.
- **Issues and Milestones:** each one's cost (its own and its PRs'), how its PRs ended, its
  waste and lead time, the most costly first, at most 100 each. On the Mac a GitHub one is a
  link.
- **The range:** a node counts when it last changed in the range, with all of its cost: a
  node's total is not kept by the day.

## Reports ▸ Saved Views, on the web page

- **Save View…** on each page of Reports keeps its scope, range and **By** under a name
  (#2019, R8). At most 50 a person.
- **Saved Views** lists them, each with **Open** (the page, its scope, range and By),
  **Copy Digest** (its numbers as a few lines of text: what was spent, the pull requests
  merged and their cost, the workflows with failed runs, the middle wait and the sessions
  that failed; a browser that refuses the clipboard is told so, #2263) and **Delete…**, which
  asks first (#2262).
- **A view is the person's own.** Nobody else sees it. A view of a scope the person no
  longer sees opens nothing: `reports/usage` checks the scope each time.
- **The control plane keeps them** in one object a person, `v1/reports/views/<user>.json`.
- **Not yet:** sending a digest each week by email or to a chat channel.

## What a machine sends

- **Each machine keeps a graph of the work** (#2348): links from a session to the issue it
  works on, the PRs it opens, and more, in `<root>/lineage.jsonl`. It keeps an ended link
  90 days and at most 20,000 links. `specs/2348-lineage/spec.md` says the rest.
- **Cost goes on the links** (#2350). When a turn's cost, tokens or time are banked, the
  machine banks them under the issues and PRs the session works on then, split evenly. A
  helper with no links of its own banks under its parent's. A turn with no link stays on
  its session. Each node's total is in `<root>/lineage-cost.json`, at most 5,000 nodes, 90
  days after the last change. `lineage/cost` adds them up to a PR, an issue (with the PRs
  that fix it), a milestone or a project, with the waste: the PRs closed without a merge
  and the merged reverts. The nodes that changed go with each `usage/rollup` (`work`).
- **The machine makes most links itself** (#2349): a session's `#n`, `P#n` or Linear-key
  label, a helper's parent, a workflow's run, the sessions on a pull request's branch and
  the issues its body closes (`Fixes #n`). A merged or closed pull request, a label taken
  off and an archived session end their links.
- **Each machine keeps its usage by the UTC hour**, by folder and runtime, in
  `<root>/report-hours.json`. It keeps 8 days.
- **A row** has the cost (by currency), the tokens (input, output, thought, cache read and
  cache write), the turns, the turns with no price, the working seconds and the waiting
  seconds. Working is the agent, its tools and waiting on others. Waiting is waiting for
  the person.
- **The counts** (#2019): the sessions that began and those that failed, the pull requests
  opened, merged and reverted, their time to merge, the waits for the person by length, and
  the workflow runs and failed runs. The agents a workflow started have rows of their own,
  with the workflow's id (`workflow`). The machine counts
  them from its own event log (`events.jsonl`) at each send, from the position it counted
  to last, and from its time ledger.
- **The folder** is the name of the folder. Thus the same repository on two
  machines adds up into one folder.
- **Each hour**, and each time the machine connects again, it sends the hours that changed
  since the last send (`usage/rollup`, on its channel 0). It also sends each UTC day that
  those hours are in, added up from its own hours. One send has at most 48 hours. If a
  send fails, the machine tries again the next hour.
- **UTC, not the machine's own time zone.** Thus machines in different time zones add up
  into the same hour and day. The Cost page on each machine keeps its own local hours, as
  before.

## What the control plane keeps

- **One file for each machine and hour**, under `v1/usage/hours/<hour>/<host>.json`, for
  7 days.
- **One file for each machine and day**, under `v1/usage/days/<day>/<host>.json`, for 90
  days.
- **A send replaces the file** for that machine and period. Only that machine writes it.
- **The hourly sweep** deletes older hours and days.
- **The cost on links** (#2350): one file for each machine, `v1/lineage/<host>.json`. A
  node sent replaces that machine's copy of it. It keeps 90 days after a node's last
  change, at most 5,000 nodes. The sweep deletes the file of a removed machine.
- **The person is the machine's owner** (#994). Each machine belongs to one user. A row of
  a machine that was removed has no person. Only an admin sees it.

## Who sees what

- **The Cost page's Reports pane** shows your own machines, also for an admin, and says
  "Your machines" (#2071).
- **Reports ▸ Spend** on the web page names its scope: your machines, a group's people's,
  or everyone's. Only an admin sees everyone's.
- **A group's lead** sees the group's people in Reports ▸ Spend, as Console ▸ Report Policy
  says.

## Methods

- `reports/usage` with a range: `day` (the last 24 hours, by the hour), `week`, `month` or
  `threeMonths` (the last 7, 30 or 90 days, by the day). It gives the rows, oldest first.
- `reports/export` with a range and a format: `csv` (the default) or `jsonl`. The CSV has
  a cost column for each currency, such as `costUSD`, then `workflow` and the counts
  (`sessions`, `failedSessions`, `prsOpened`, `prsMerged`, `prsReverted`, `mergeSeconds`,
  `waits`, `workflowRuns`, `workflowFailures`; blank from a machine before #2019), then
  `groups`.

- `reports/value` (#2351) with a range and a scope: Reports ▸ Value (`ReportValue`).
- `reports/views`, `reports/saveView` (a view with no `id` is new) and `reports/deleteView`
  (#2019): the caller's saved views.

## Reading the reports from another tool

### The read API

A BI tool reads the organisation's reports over HTTPS with a token an admin made in
Console ▸ Read API (#2019):

```sh
curl -H "Authorization: Bearer agread_…" \
  "https://control.example.com/v1/read/reports?range=month&format=csv"
```

- `range` is `day`, `week`, `month` (the default) or `threeMonths`, as for `reports/usage`.
- `format` is `json` (the default, the same answer as `reports/usage`), `csv` or `jsonl`
  (the same as `reports/export`).
- `group=<id>` reads one group's rows instead of the organisation's.
- **A token reads these reports and nothing else.** It opens no socket and calls no
  method.
- **The control plane keeps only the token's SHA-256.** The value is shown once.
- **Each token asks at most 30 times a minute.** Past that, the answer is 429 with
  `Retry-After`.
- **A token stops** when an admin revokes it, or when the admin who made it is no longer
  an admin. At most 10 tokens are live, and 50 are kept, revoked ones too.

### OTLP metrics

agents-control sends today's figures to an OpenTelemetry collector over OTLP/HTTP (JSON)
when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. It is off by default.

| Variable | What it does |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | The collector. The exporter sends to it with `/v1/metrics` added. |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | The full URL, in place of the one above. |
| `OTEL_EXPORTER_OTLP_HEADERS` | Headers as `key=value,key=value` (values URL-encoded), such as `authorization=Bearer%20…`. |
| `OTEL_METRIC_EXPORT_INTERVAL` | Milliseconds between sends: 300000 (5 minutes) by default, 60000 at least. |

Each metric is a cumulative sum that starts at midnight UTC, by runtime:
`agents.cost` (by currency), `agents.tokens` (by kind), `agents.turns`,
`agents.sessions` (ended or failed), `agents.pull_requests` (opened, merged, reverted),
`agents.workflow.runs` (succeeded or failed) and `agents.time` (working or waiting, in
seconds). No person, folder or machine is named. Console ▸ Read API shows where the
exporter sends and how its last send went. For the control plane's own health, use the
Prometheus metrics (`AGENTS_CONTROL_METRICS`, #2176).

## See also

- [The Console](console.md): Report Policy, the leads and the budgets.

- [Events](events.md): the audit, which says who did what.
