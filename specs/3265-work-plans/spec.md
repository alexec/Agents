# Plans in Work (#3265)

One lead does a feature's work from start to end. The work is a set of related issues
in a given order. This spec gives the work one hierarchy and one set of names. It also
shows the hierarchy and the order in the Work view, and adds **Start lead** to start the
one session that does the work.

Alex chose option 1 on 2026-11-02: the forge's parent issue is the epic, and the Work
view shows it as a plan. The other options were a plan file in the repo and a lead
session with no epic object.

## The hierarchy

| Level | What it is | On the forge | How long | Who works it |
|---|---|---|---|---|
| **Feature** | A product theme, such as Work, Lineage or Hosted. It spans epics and milestones. | the label `feature:<name>` | months | nobody directly |
| **Epic** | A deliverable with a plan: its child issues in order | a parent issue, label `epic` | one milestone, or none | **one lead** |
| **Story** | A slice that a person can see or use: a client or a workflow changes | a sub-issue, label `story` | one lane | a lane: one PR or one stack |
| **Task** | A slice that changes no client: the daemon, the wire, tooling or docs | a sub-issue, label `task` | one lane | a lane: one PR |
| **Spike** | A question with a time limit. Its output is a decision in the issue or a spec, not product code. | a sub-issue, label `spike` | hours | a lane, or the lead |
| **Bug** | stays as it is today. It can also be the child of an epic. | label `bug` | | the bug lane, or the epic's lead |

- **A feature is a label, not an issue.** A feature lasts longer than any one epic. For
  example, `feature:work` holds #3100 (Work pages), #3247 (Jira), #3256 (the Remote) and
  this epic. A label lets one issue be in a feature with no parent issue that must stay
  open for ever.
- **`feature:` is not `area:`.** `area:<name>` is a lock on a set of paths, so that two
  lanes do not change the same files (#873). CI sets it from the paths that a PR
  changes. `feature:<name>` is a product theme that the Product Owner sets when it files
  the issue. They often have the same name, but they do not have to.
- **An epic belongs to one feature,** and its children get the same `feature:` label.
- **`bug` and `enhancement` stay** as the type labels. The rules in AGENTS.md use them
  (for example, "A UI enhancement waits for Alex"). `story`, `task` and `spike` give the
  level, and are used in addition to the type label. A story or a task is also an
  `enhancement`.

### The order

- **The order is in the forge's dependencies, not in prose.** On GitHub, a child is
  "blocked by" another child (`blockedBy`, which this repo already has). On Linear, it is
  a "blocks" relation. On GitLab, it is a "blocks" link (on the Premium tier only; on
  Free, the order is not known and every child is in step 1). Jira links come with #3247.
- **A step** is the set of children whose blockers are all closed or in an earlier step
  (a topological sort). The children of one step can run at the same time, under the
  area and open-PR limits.
- The "Slices" table in an epic's body, as in #3100, becomes optional prose. The plan is
  built from the sub-issues and their dependencies, so it cannot go out of date.

## In the Work view (Mac + web)

### The epic's page: a Plan section

The issue page of an issue that has sub-issues shows **Plan** above the comments.

```
#3100  Epic: Work pages                                         feature:work · 0.16
● Lead: "Work pages lead" (running)        5/7 done · 1 running · $41.20      [Open lead]

Plan
┌ Step 1 ───────────────────────────────────────────────────────────────────────────┐
│ ✓ task   #3118 reports/nodes              PR #3121 merged          $4.10          │
│ ✓ task   #3129 forge reads                PR #3133 merged          $6.80          │
├ Step 2 ───────────────────────────────────────────────────────────────────────────┤
│ ✓ story  #3119 lists + pages              PR #3140 merged          $9.30          │
├ Step 3 ───────────────────────────────────────────────────────────────────────────┤
│ ✓ story  #3130 actions                    PR #3252 merged          $12.00         │
│ ◐ story  #3088 lineage links              ● lane running · PR #3266 needs approval │
├ Step 4 · waits for #3088 ─────────────────────────────────────────────────────────┤
│ ○ story  #3131 retire connector rows                                              │
└───────────────────────────────────────────────────────────────────────────────────┘
[Start lead]  (when no lead runs)
```

- **Each row** shows the level, the issue, its state, and the session and PR that work on
  it (from lineage), with the cost. A click opens the issue's page. Previous and Next go
  through the plan (#3257).
- **The row's mark** is one of: ✓ closed; ◐ a lane runs or a PR is open; ⚠ a question
  waits, a check failed or the PR needs approval; ○ waiting; ⊘ blocked by an open issue
  in another epic.
- **The header** shows the lead session (if any), the count of closed children, the
  count of running children and the total cost.
- **Start lead** (see below) shows when no session for this epic runs. When one does, the
  header shows **Open lead** instead.

### Work ▸ Features

The Work view gets a third list next to Issues and PRs: **Features**. Each feature is a
`feature:` label. It shows the feature's open epics, each with its progress and lead:

```
Features
▾ Work                                       3 epics · 2 open
    #3265  Plans in Work            1/6   ● lead running
    #3100  Work pages               5/7   ● lead running
    #3247  Jira                     0/3   —
▸ Lineage                                    4 epics · 0 open
▸ Hosted                                     6 epics · 1 open
```

- A click on a feature opens its list of epics and loose issues (the issues with the
  label and no parent epic).
- Issues that have no `feature:` label are not in this list. They are still in Issues.

### The sidebar: the lead's row

The sidebar already puts a lead's lanes one step in, under the lead
(`docs/reference/sidebar.md`, "Sessions under the session that started them"). A lead
session that has an epic shows the epic's progress after its title, such as
`Work pages lead · 5/7`. When it is folded, it shows the most urgent mark of its lanes,
as it does today.

## The lead

- **Start lead** starts one session in the epic's folder. Its prompt is the epic's link,
  and it uses the lead skill. Its labels are `#<epic>` and `lead`. A Start lead in Work
  uses the same `forge/start` path as Start Agent (#3130).
- **The lead** reads the plan (`forge/plan`) and starts a lane for each child of the
  first open step with `start_session`. It does this within the folder's lane limits and
  the area limit (#873). It waits on `pr.merged`, `issue.closed`, `checks.failed` and
  `pr.conflicted` for its children. When the last blocker of a child closes, it starts
  that child's lane. It does not write code itself. When a spike is small, the lead can
  do it itself.
- **The lead owns the plan.** When a lane finds new work, the lead files a new child
  and sets its blockers. The Product Owner files the epic and its first set of children.
- **When all children are closed,** the lead closes the epic, posts a summary comment
  (what merged and what it cost) and archives itself.
- **The Scrum Master** gives a place to an epic's lead, not to each of its children. The
  lead's lanes count towards the folder's lane and open-PR limits, as all lanes do. The
  milestone order and the "UI changes go early" rule apply to the epic as one unit.

## The wire (daemon)

- `ForgeItem` gets `parent` (a node, if any), `level` (`epic`, `story`, `task`, `spike`
  or empty, from the labels), `feature` (from the `feature:` label) and
  `progress` (`{done, total}`, for a parent only).
- A new method, `forge/plan {node}`, returns the epic's children as `ForgeItem`s, each
  with `blockedBy` (nodes) and `step`. It also returns the steps and the lead session,
  from lineage (a session labelled `#<epic>` and `lead`).
- `ForgeListRequest` gets `feature` (a filter). `forge/features {folder}` returns the
  `feature:` labels with their epic counts.
- GitHub: `subIssues`, `parent`, `blockedBy` (GraphQL). Linear: `parent`, `children`,
  `relations` of type `blocks`. GitLab: the epic's issues and "blocks" links (Premium).
  When a forge has no dependencies, every child is in step 1.

## Slices (one agent and one PR each)

| # | Level | What | Clients | Blocked by |
|---|---|---|---|---|
| 1 | task | The process: AGENTS.md "Plans: features, epics, stories, tasks, spikes", the Product Owner and Scrum Master personas, and a `lead` skill in `.agents/skills/lead/` | docs only | — |
| 2 | task | The wire and daemon: `ForgeItem` hierarchy fields, `forge/plan`, `forge/features`, the `feature` filter, for GitHub, Linear and GitLab | no | — |
| 3 | story | The Plan section and Start lead / Open lead on the issue page | Mac + web, `needs-approval` | 2 |
| 4 | story | Work ▸ Features | Mac + web, `needs-approval` | 2 |
| 5 | story | The lead's sidebar row shows the epic's progress | Mac + web | 3 |
| 6 | story | Change the plan from the page: Add child, set "blocked by" (forge writes) | Mac + web, `needs-approval` | 3 |

Slices 1 and 2 can run at the same time.

## Decided (Alex can overrule)

- Decided: a feature is the label `feature:<name>`, not an issue, because a feature
  outlasts its epics and an issue that stays open for ever is noise.
- Decided: `epic`, `story`, `task` and `spike` are labels used in addition to
  `bug`/`enhancement`, because the AGENTS.md rules depend on the type labels. This
  repo is owned by a user, not an organisation, so GitHub's issue types are not
  available to it.
- Decided: the forge's sub-issues and "blocked by" links hold the plan, not a file in the
  repo, because other people and other tools read them too, and GitHub, Linear and Jira
  all have them.
- Decided: tier **Mac + web**, as for the Work pages (#3100). The Remote follows #3256.
- Decided: the lead owns its plan after the Product Owner files it, because the lead
  sees the new work first.
- Decided: in milestone 0.16, because the plan is part of the Work view, which is that
  milestone's goal.

## Settled (Alex, 2026-11-02)

- The lead does not count as a lane. Its lanes count: typically 5 to 7 at once, per
  project.
- Closed epics keep their labels. Only open issues get `epic` and `feature:`.
- The app says "epic" for every forge, also for Linear.
