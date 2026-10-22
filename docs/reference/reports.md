---
diataxis: reference
devices: [mac, iphone, ipad]
description: Usage, cost and time by person, project, machine and runtime, added up on the control plane from what each machine sends.
---

# Reports

A report shows the usage, cost and time of each person, project, machine and runtime
(#1811). The control plane adds them up from what each machine sends.

## The Reports pane

The Cost page has two panes, **Cost** and **Reports**, on the Mac, the Remote and the web
page.

- **The range:** D (the last 24 hours, by the hour), W, M or 3M (the last 7, 30 or 90
  days, by the day), as the Cost page's charts.
- **By:** Person, Project, Machine or Runtime. The first line is the total. Under it is a
  line for each person, project, machine or runtime, largest first, with a bar for its
  share of the largest. Each line says the cost, the tokens, the turns and the working
  time.
- **Export** saves the rows of the range as CSV or as JSON lines.
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

The Mac and the Remote show the Me scope only.

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

## What a machine sends

- **Each machine keeps its usage by the UTC hour**, by project and runtime, in
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
- **The project** is the name of the project's folder. Thus the same repository on two
  machines adds up into one project.
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

## See also

- [The Console](console.md): Report Policy, the leads and the budgets.

- [Events](events.md): the audit, which says who did what.
