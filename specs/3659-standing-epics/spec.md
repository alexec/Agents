# Standing epics (#3659)

Status: the spike (#3660) is done. This file holds its decision. `forge/plan` for a
standing epic (#3661) builds on it.

A **standing epic** is an epic whose plan is a query, not sub-issues. It never closes.
The bug lane, and the lane for `polish` and `competitor`, are the first two (#1570,
#3212). See #3659 for why.

## The question

How does a standing epic keep its query and its order on GitHub, GitLab, Linear and
Jira, so that the plan is in the forge and not in prose?

## What each forge has

| Forge | A saved query | Can the daemon read it? | Priority |
|---|---|---|---|
| GitHub | Saved searches on the issues dashboard | No: there is no API for them | labels only |
| GitLab | Saved filters on the issue list are per user, in the browser | No | labels (Free); weight (Premium) |
| Linear | Custom views (`customView.filterData`) | Yes, with Linear's own filter syntax | a field, 0–4 |
| Jira | Filters (JQL) | Yes, with JQL | a field |

Each forge that has a saved query has its own syntax. Two have none that the daemon can
read. The daemon already reads issues on every forge with a label filter and an open
state (`forge/issues`, #3129).

## Decided

Decided: the query is a fenced block in the epic's body, in a small set of fields that
the daemon changes into each forge's own filter, because it is the one form that every
forge can store and that the daemon can read. A person sees it on the issue and edits it
there, and the issue's history keeps the old versions. Alex can overrule.

Decided: an epic is standing when it has the label `standing` as well as `epic`, because
a label is cheap to list on every forge (Work ▸ Features, the Scrum Master) and the
body is not. A `standing` epic with no block, or a bad one, has a plan with an error that
says so. Alex can overrule.

Decided: the order is the forge's priority, then the oldest first. Priority is Linear's
or Jira's priority field, else the labels `priority:high`, `priority:medium` and
`priority:low`. An issue with no priority goes between medium and low. Alex can
overrule. Why:
- RICE is not a field on any forge. The Product Owner ranks with RICE and writes the
  result as a priority. So the order a person sees on the forge is the order the lead
  takes.
- The daemon's estimate (#3557) is effort only, not reach, impact or confidence. The
  plan shows it beside each row, but it does not change the order.
- Oldest first, so that no issue waits for ever behind newer ones of the same priority.

Decided: a standing epic holds 1 lane at a time, unless its block says `lanes:`, because
that is what the bug lane and the polish lane hold today. It is never more than the
folder's lane limit. The Scrum Master gives the lead its place in the AGENTS.md order: the
bug lane with the milestones' epics, `polish` and `competitor` after them. When places run
short, a standing epic's lane is paused before a milestone epic's lane. Alex can
overrule.

## The block

````markdown
```standing
labels: bug
milestone: none
lanes: 1
```
````

| Field | Says | When left out |
|---|---|---|
| `labels` | the issue has all of these labels | no filter |
| `any` | the issue has at least one of these labels | no filter |
| `not` | the issue has none of these labels | no filter |
| `milestone` | `none`, `any`, or a milestone's name | no filter |
| `lanes` | how many lanes the lead runs at once, 1 or more | 1 |

- Lists are comma-separated. Field names and label names are not case-sensitive.
- An unknown field is an error, so a typo is not ignored.
- The query is always open issues, never pull requests. It always leaves out epics:
  an epic is not a lane's work.
- There is one block. A second one is an error.

The two standing epics of this repo:

| Epic | Block |
|---|---|
| Bug lane | `labels: bug` · `milestone: none` |
| Polish and competitor gaps | `any: polish, competitor` · `milestone: none` |

### On each forge

| Field | GitHub (search) | GitLab (issues API) | Linear (`IssueFilter`) | Jira (JQL) |
|---|---|---|---|---|
| open | `is:issue is:open` | `state=opened` | `state.type nin [completed, canceled]` | `statusCategory != Done` |
| `labels` | `label:a label:b` | `labels=a,b` | `labels: {and: [{some: {name: {eqIgnoreCase}}}…]}` | `labels = a AND labels = b` |
| `any` | `label:a,b` | one call per label, merged | `labels: {some: {name: {in}}}` | `labels in (a, b)` |
| `not` | `-label:a` | `not[labels]=a` | `labels: {every: {name: {nin}}}` | `labels not in (a)` |
| `milestone: none` | `no:milestone` | `milestone=None` | `projectMilestone: {null: true}` | `fixVersion is EMPTY` |
| `milestone: <name>` | `milestone:"<name>"` | `milestone=<name>` | `projectMilestone.name` | `fixVersion = "<name>"` |
| epics left out | `-label:epic` | `not[labels]=epic` | no children (`children: {length: 0}`) and no `epic` label | `issuetype != Epic AND labels != epic` |

- Forgejo uses GitHub's form (its issue search takes labels and milestones). Azure
  Boards uses tags in WIQL. Bitbucket has no plans (`bitbucketNoPlan`), so it has no
  standing epics either.
- The forge sorts by its newest first. The daemon then orders the list by priority and
  age itself, so the order is the same on every forge.

## The shape of `forge/plan` (#3661)

The wire first (`Packages/Wire/daemon.schema.json`, then `scripts/wire.sh gen`):

- **`ForgeItem.standing`** (boolean): the item has the label `standing`. Set in
  `withHierarchy` with `level`, so the Work view knows a standing epic in any list.
- **`ForgePlan.standing`** (optional `ForgeStanding`), set only for a standing epic:
  - `labels`, `any`, `not` (string arrays) and `milestone` (string): the block as the
    daemon read it, so a client can show it;
  - `lanes` (integer): from the block, else 1;
  - `error` (string, optional): no block, a second block, or an unknown field. With an
    error, `children` is empty.
- **`children`** for a standing epic are the query's open issues in order (above), at
  most 100. Each has `step: 1`, and its `blockedBy` and `blockedOutside` from the forge,
  as for a child. The lead skips an issue with an open blocker.
- **`steps`** is one step, with every child. A client that does not know `standing`
  still draws a correct plan. A client that knows it draws no step header.
- **`item.progress`** is not set: a standing epic has no "done of total".
- **`lead`** is found as for any epic.
- The answer is cached with the other plans (`forgeRemember`), and `resolvedFromForge`
  gets its items.

In the daemon:

- `forgePlan` reads the epic as it does today. When the epic has the label `standing`,
  it parses the block from the body and calls a new `standingPlan` instead of the
  forge's sub-issue read.
- `standingPlan` changes the block into the forge's filter (the table above) on the
  same connection that `forge/issues` uses. The GitHub one adds `no:milestone`,
  `-label:` and `label:a,b` to `searchIssues`.
- The order is a pure function of the items, tested by itself.

## As built (#3661)

Decided: the daemon reads the list with `forge/issues` on the epic's folder, narrowed on the
forge by the block's first label, and applies the rest of the query itself, at most 5 pages of
100. The per-forge filters in the table above are not used yet, because one read works the same
on every forge with no change to their clients. Alex can overrule.

- Priority is the `priority:` labels only: `ForgeItem` has no priority field for Linear or Jira.
- "The oldest" is the lowest issue number: `ForgeItem` has no creation date.
- Only the epic's own repo, Linear team or Jira project is read.
- Each child's `blockedBy` is empty for now: a list does not read blockers.

## Not in this spike

- The lead skill's steps for a standing epic: it never closes the epic, and it waits on
  `issue.opened` and `issue.labeled` as well. That is a change to the `lead` skill, after
  #3661.
- The Plan section on the Work page for a standing epic (Mac + web).
- Moving AGENTS.md's bug-lane and polish-lane rules into the two standing epics.

## Direction (#3403)

The query lives on the customer's own forge, in the issue body, read with the
customer's own connection. Nothing new is hosted or stored by us.
