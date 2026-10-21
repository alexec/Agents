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

## What a machine sends

- **Each machine keeps its usage by the UTC hour**, by project and runtime, in
  `<root>/report-hours.json`. It keeps 8 days.
- **A row** has the cost (by currency), the tokens (input, output, thought, cache read and
  cache write), the turns, the turns with no price, the working seconds and the waiting
  seconds. Working is the agent, its tools and waiting on others. Waiting is waiting for
  the person.
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

- **An admin** sees every person's machines.
- **A member** sees only their own machines.

## Methods

- `reports/usage` with a range: `day` (the last 24 hours, by the hour), `week`, `month` or
  `threeMonths` (the last 7, 30 or 90 days, by the day). It gives the rows, oldest first.
- `reports/export` with a range and a format: `csv` (the default) or `jsonl`. The CSV has
  a cost column for each currency, such as `costUSD`.

## See also

- [Events](events.md): the audit, which says who did what.
