# Reports: one lens bar, pages grouped by question (#5205)

Status: decided (Alex, 2026-11-13). Tier: Web + Mac link (#4937). Web only to build; the Mac's
Cost ▸ Open Reports link keeps working.

## The problem

Alex (#5205): "In most cases a report wants to be run for a user, project, team, and org. Maybe all
reports should support all lenses? Maybe we should group them?"

### What Reports has now (`Web/src/model/console.ts` `reportSections`, `Web/src/model/nav.ts`)

| Page | Group in the list | Lenses it takes | Notes |
|---|---|---|---|
| Spend | Reports | Me, group, org | By person, project, folder, machine, runtime (+ group past Me); budget; export |
| Outcomes | Reports | Me, group, org | Counts pane |
| Time | Reports | Me, group, org | Counts pane: working against waiting |
| Planning | Reports | Me, group, org | Cost per PR, waste, lead time, Delivery (DORA), what comes next, What if, estimates, issues, releases |
| Runtimes | Reports | Me, group, org | Counts pane by runtime |
| Adoption | Reports | Me, group, org | Who uses agents each week |
| Workflows | Reports | Me, group, org | Counts pane by workflow |
| Features | Reports | none (the caller's machines) | Product telemetry: methods and tools used |
| Saved Views | Saved | n/a | A list of saved pages, not a report |
| Multiplier | Yours | Me only | |
| Usage | Yours | Me only | Cost, Tokens, Time, Velocity: as the Mac's Usage |
| Audit | Records | admin | Admin only |

### What is wrong

1. **No project lens.** "Project" is only a way to add up (By ▸ Project). Nobody can open
   "Project X's spend, outcomes and plan" for all the people who work on it.
2. **The lens is not the same on every page.** Seven pages take Me, group and org. Features takes
   none. Multiplier and Usage are Me only, in a group of their own. A person cannot tell which
   pages a lens applies to.
3. **The lens picker hides.** It shows only when the caller has more than one lens, and not on
   Features or Saved Views. It sits above the page, apart from Range and By. A member never sees
   that a lens exists.
4. **Pages repeat each other.** Usage ▸ Cost and Time are Spend and Time in the Me lens. Runtimes
   is Spend + Outcomes by runtime. Workflows is Spend + Outcomes by workflow.
5. **The list is flat and the names do not say the question.** Eight pages in one "Reports" group;
   "Planning" holds six different reports (cost per PR, DORA, forecasts, What if, estimates, issue
   rows). "Features" is about the product, not about the person's work.
6. **Words.** The code says "scope", the issue says "lens", the people page says "group", and
   Alex says "team".
7. **A small bug:** Planning's footer names no group: "The machines of the group's people"
   (`scopeNote(scope, undefined)`, `Web/src/views/Reports.tsx:444`).

## Decisions (Alex, 2026-11-13)

- **The lenses are Me, Project and Organisation.** There is no team or group lens: Alex adds
  no new concept now, and the group scope of #1804 leaves Reports.
- **Anyone who can see a project can see its lens.** The control plane shows every project to
  every signed-in person (`projectList`, `Go/internal/controlplane/projects.go`), so every person
  sees every project's lens: all the rows of the project's folders, on every person's machines.
- Decided: option A (one lens bar, pages grouped by question), because it was the recommended
  option and Alex objected only to the team lens. Alex can overrule.
- Decided: Features moves to Status, because it is about the product and the machines, not about
  work. Alex can overrule.
- Decided: the Mac's Cost ▸ Open Reports does not change, because an address with no `lens`
  opens the Me lens. Alex can overrule.

## Options

### A. One lens bar on every page, and pages grouped by question (recommended)

Every report takes every lens: **Me · Project · Organisation**. The lens bar is always at
the top of the page, in the same place, with Range beside it. The lens stays when the person
moves to another page, and it is in the address (`#/reports/spend?lens=project:<id>&range=week`), so
a saved view and the Mac's link carry it. A lens the person may not see is not in the bar; a
member sees Me and every project.

The list groups the pages by the question they answer:

| Question | Pages | From |
|---|---|---|
| **Cost** – what did it cost? | Spend (with budget) | Spend; Usage ▸ Cost, Tokens |
| **Output** – what did it ship? | Outcomes, Delivery | Outcomes; Planning ▸ cost per PR, waste, Delivery |
| **Time** – where did the time go? | Time | Time; Usage ▸ Time |
| **Plan** – what comes next? | Forecast, Estimates | Planning ▸ what comes next, What if, estimates |
| **Use** – who uses what? | Adoption, Runtimes, Workflows | as now |
| Saved | Saved Views | as now |

Usage (Velocity) and Multiplier go into the Me lens of the page they repeat. Features moves to
Status (it is about the product and the machines, not about work), or stays in Use with the
line "Your machines only". Runtimes and Workflows stay as pages for now: they are the By ▸ Runtime
and By ▸ Workflow of Cost and Output, but people look for them by name.

Cost: a wire change (a project lens), a control plane change, two web stories. No Mac or Remote
change except the link's address.

### B. One lens bar only, pages as now

The same lens bar and project lens as A, with no regrouping. Smallest change. It fixes problems
1–3 and 6, and leaves the flat list and the repeats (4, 5).

### C. A page per lens

Reports opens on three pages, Me, Project and Organisation, each a dashboard with one card per
report (spend, shipped, time, forecast, adoption), and each card links to its full report in that
lens. It reads best for "run this for project X", but it adds three new pages and a card for each
report, and the full reports still need the lens bar of A. It can come after A.

## Wireframe (option A)

```
┌ Overview  Agents  Work  Machines  Workflows  [Reports]  People  Settings ───────────────┐
│ COST          │  Lens  (Me)( Project: Agents ▾ )( Organisation )         Range [Last 7 days ▾] │
│  Spend        │  ─────────────────────────────────────────────────────────────────────────  │
│ OUTPUT        │  Spend · Project Agents                                  Save View…  Export ▾│
│  Outcomes     │  $412.80 of $600 this month · forecast $590.00                              │
│  Delivery     │  ████████████████████████░░░░░░░                                            │
│ TIME          │  By (Person)(Folder)(Machine)(Runtime)                                       │
│  Time         │   Ana Ruiz        $180.20 · 9.1M tokens · 211 turns · 14 h working  ███████ │
│ PLAN          │   Ben Ode         $121.00 · 6.0M tokens · 160 turns ·  9 h working  █████   │
│  Forecast     │   …                                                                          │
│  Estimates    │  The folders of Agents, on every machine. Hours are UTC.                 │
│ USE           │  Last update 2 min ago                                                       │
│  Adoption     │                                                                              │
│  Runtimes     │                                                                              │
│  Workflows    │                                                                              │
│ SAVED         │                                                                              │
│  Saved Views  │                                                                              │
└───────────────┴──────────────────────────────────────────────────────────────────────────────┘
```

- The lens bar is the first row of every page, also for a member (Me and their projects).
- Project ▾ opens the list of projects; the bar then
  shows the name: `( Project: Agents ▾ )`.
- The page title says the lens: "Spend · Project Agents".
- By leaves out the lens's own dimension (no By ▸ Project in a project lens).
- Narrow page (< 760): the lens bar is one menu, "Lens: Project Agents ▾", above Range.

## Who sees which lens

| Lens | Who sees it | Whose rows |
|---|---|---|
| Me | everyone | the caller's machines |
| Project | everyone who can see the project (now: every signed-in person) | every row whose folder is in the project, on every machine |
| Organisation | admins | everyone |

## Plan

The epic and its sub-issues on the forge are the plan (`feature:reports`).
