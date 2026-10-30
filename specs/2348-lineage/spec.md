# Lineage 1: a typed graph of the SDLC, stored as files (#2348)

Part of #2347 (slice 1 of 5). Milestone 0.14 Lineage and value.

## What it is

A graph that links the parts of the SDLC. The host keeps it. The other slices fill it
(#2349), put cost on it (#2350) and show it (#2351, #2352).

- **A node** is a `kind` and a `ref`.
  - `kind`: `issue`, `pr`, `session`, `workflow-run`, `commit`, `file`, `branch`,
    `milestone`. The list is open.
  - `ref` names the node apart from any tracker, as `<scheme>:<id>`:
    `github:alexec/Agents#123`, `gitlab:group/repo!45`, `linear:ENG-4`, `jira:ABC-9`,
    `session:<agent id>`.
  - A node is in the graph while a link names it. Nothing stores a node on its own.
- **A link** has `from`, `to`, `rel`, `source`, `at`, and `endedAt` when it stops being
  active.
  - `rel`: `works-on`, `opens`, `fixes`, `started`, `reviews`, `closes`, `part-of`. The
    list is open.
  - `source` (how the host knows it): `start`, `branch`, `pr-body`, `helper`, `agent`,
    `person`. The list is open.
  - At most one link from, to, rel is active at a time. To link it again while it is active
    changes nothing. An ended link can start again, as a new link.
  - Many-to-many needs nothing more: one session opens many PRs, and many sessions work on
    one issue.
- **The lists are open.** In the schema, `kind`, `rel` and `source` are strings, not
  enums: a generated enum reads a value that it does not know as its default, and that
  would change a newer host's links. The host refuses only words that are not in the
  format (lower case letters, digits and `-`). The refs it refuses are refs without a
  scheme and refs longer than 512 bytes.

## The store

- **One interface,** `lineage.Store` in `Go/internal/lineage`: `Link`, `End`, `Links`,
  `Walk`, `Close`. A graph database can replace the files behind it (Alex, 2026-10-22).
- **Files:** `<root>/lineage.jsonl` on each machine.
  - Each change is one line, written with one write to an `O_APPEND` file: a link started
    (`{"link": …}`) or a link ended (`{"end": {from, to, rel}, "at": …}`).
  - A torn last line is dropped. A line in the middle that cannot be read is left out: the
    file is copied to `lineage.jsonl.unreadable-<time>`, and what the host can read is
    written again.
  - When the file has 2,000 lines more than the links it keeps, the host writes it again
    whole, through a temporary file and a rename. An ended link is then one line.
- **Bounds:**
  - An ended link is kept for 90 days after its end.
  - The store keeps at most 20,000 links. The oldest ended links go first, then the oldest
    active links.
  - An answer holds at most 500 links. A walk reaches at most 500 nodes, at most 4 links
    away. `limited` says when there is more.

## The wire

These types are in `Packages/Wire/daemon.schema.json`: `LineageNode`, `LineageLink`,
`LineageLinkRequest`, `LineageEndRequest`, `LineageNodeRequest`, `LineageLinks`,
`LineageGraph`. The methods are in `daemon.openrpc.json`, capability `lineage/1`:

| Method | Params | Result |
| --- | --- | --- |
| `lineage/link` | `LineageLinkRequest` | the link, new or the one that was active |
| `lineage/end` | `LineageEndRequest` | the link it ended, or none |
| `lineage/links` | `LineageNodeRequest` | the node's links, both ways, newest first |
| `lineage/walk` | `LineageNodeRequest` (`depth` 1–4, default 2) | the nodes and links in reach |

A person's connection (the window, the Remote, the web page) can call them. An agent's
connection cannot: slice 2 gives agents a tool.

The default walk is 2 links, because 2 links go from an issue to its sessions and from
the sessions to their PRs. The walk follows links in both directions.

## Decisions on the open questions

- **Decided: the limit is both: 90 days after a link ends, and 20,000 links. A merged PR's
  links do not stay longer.** Because the control plane keeps its days for 90 days, and
  the count stops a busy machine from growing without a limit. Slice 3's totals on the
  control plane keep the cost after the links go. Alex can overrule.
- **Decided: an event or a person sets the end time.** This slice gives `lineage/end`,
  which a person can call. Slice 2 (#2349) ends links on events: a PR merged or closed, a
  session archived. Alex can overrule.
- **Decided: a `lineage` area in `.agents/areas`.** Because slices 2 to 5 change these
  files one after another, and `reports` is a broad area that other lanes hold. Alex can
  overrule.
- **Decided: the rollup to the control plane goes with slice 3 (#2350), not this slice.**
  Because the control plane needs the links to add up cost by PR, issue and milestone,
  and nothing reads links there before cost goes on them. A rollup of links only would fix
  a format that slice 3 must then change. Alex can overrule.
- **Decided: the file is `lineage.jsonl`, not `links.jsonl`.** Because "links" also means
  a file's hard links on the host (`links.go`). Alex can overrule.

## The links the host makes (#2349)

Slice 2 makes most links without help, in `Go/internal/agentsd/lineagelinks.go`. One
goroutine writes them in order, away from the agent lock.

| What happens | The link | `source` |
| --- | --- | --- |
| A session starts with the label `#n`, `P#n` or a Linear key (the Issues and PR pages give one) | session `works-on` the issue or PR | `start` |
| The agent (`set_session_labels`) or the person adds such a label later | session `works-on` the issue or PR | `agent` or `person` |
| The label is taken off | that link ends | |
| A helper starts | parent session `started` helper | `helper` |
| A workflow's session starts | run `started` session, run `part-of` workflow | `helper` |
| `pr.opened` | **every** session on the PR's branch, in the PR's repo, `opens` the PR | `branch` |
| `pr.opened`, `pr.merged`: the PR's body says `Fixes #n`, `Closes #n`, `Resolves o/r#n` | PR `fixes` the issue | `pr-body` |
| `pr.merged` or `pr.closed` | the sessions' links to the PR end | |
| `pr.closed` (no merge) | the PR's `fixes` links end too: it fixed nothing | |
| A session is archived | the links from it end | |

- **Refs.** The folder's `origin` remote names the repo for `#n` and `P#n`:
  `github:<owner>/<repo>#n`, or on GitLab `gitlab:<group>/<project>#n` for an issue and
  `…!n` for a merge request. The path is lower case. A Linear key is `linear:<KEY>`. A
  workflow is `workflow:<folder>/<workflow id>`, a run `run:<run id>`.
- **The GitHub and GitLab servers** add `pr.fixes` to `pr.opened`, `pr.merged` and
  `pr.closed`: the issues the PR's body closes (`#12`, or `owner/repo#12` for another
  repo's), at most 20.
- **The host hears a PR event only while a workflow or a wait listens for it** (as for
  Reports). A session's `P#n` label links it to its PR without one.

### Decisions on slice 2's open questions

- **Decided: no new tool; `set_session_labels` is the tool**, because agents label their
  work with `#n` and `P#n` already (AGENTS.md), and each tool listed costs tokens in every
  session. Its description says that a label links. Alex can overrule.
- **Decided: taking a `#n` label off ends the link.** Because an active link is what the
  work is on now: #2350 banks a turn's cost under the active links, and an ended link
  stays in the graph as history. Alex can overrule.

## Cost on the link (#2350)

Slice 3 banks each turn's cost under the links, in `Go/internal/agentsd/lineagecost.go`,
and adds it up in `Go/internal/lineage/cost.go`.

- **What is banked:** the cost of each `usage_update` (what the session's total rose by),
  the tokens and the turn when the turn ends, and the time (the agent, its tools and
  others at work; waiting for the person) when the time ledger banks it.
- **Where it goes:** the session's **active** `works-on`, `opens` and `reviews` links to an
  issue or a PR, split evenly (#2347). The tokens are whole: the first shares take what is
  left over. `turns` is a share, so a turn on two nodes is half a turn on each.
- **A helper** with no work of its own banks under its parent's work: the session that
  `started` it, and so on up, at most 4 sessions. A helper with its own `#n` (a lane that
  the Scrum Master started) banks under that.
- **What is banked stays.** A label changed later moves nothing (#829).
- **The order:** the banking runs on the linker's goroutine, after the links made before
  it, so a turn sees the links made before it ended.
- **The file:** `<root>/lineage-cost.json`, one total per node (`LineageCostNode`), saved
  at most every 30 seconds and at shutdown. It keeps a node 90 days after its last change,
  and at most 5,000 nodes; the oldest go first.
- **A PR's end** is on its node (`outcome`): `merged`, `closed` (without a merge) or
  `reverted` (a merged PR whose title starts `Revert`, as Reports counts `prsReverted`).
  `checks.failed` counts its failed CI rounds (`failedChecks`). A PR closed without a merge
  also links the issues its body closes, and those links end at once: it fixed nothing,
  but its cost stays against them.

### The rollups

`lineage/cost` (`LineageNodeRequest` → `LineageCostRollup`, capability `lineage/1`) adds up
a node from this machine's totals. Each part counts once.

| Node | Its parts |
| --- | --- |
| A PR, a session, any other node | itself |
| An issue | itself, and the PRs that fix it (ended `fixes` links too) |
| A milestone | the issues and PRs `part-of` it, and the PRs that fix those issues |
| A project (`kind` `project`, `ref` `github:alexec/agents`) | every node in that repo or tracker |

- `own` is what was banked on the node itself, `total` adds its parts, `waste` is the
  parts' PRs closed without a merge or reverted, and `unlinked` is the parts' sessions:
  the turns with no active link.
- `parts` is the nodes added up, newest first, at most 500.

### The control plane

- Each `usage/rollup` has `work`: the nodes whose total or rollup links changed since the
  last send, each whole, at most 1,000 in one send.
- The control plane keeps them in `v1/lineage/<host>.json`: a node sent replaces that
  machine's copy. It keeps a node 90 days after its last change, at most 5,000 a machine.
  The sweep deletes the file of a removed machine, when it is a day old.
- The read of these on the control plane comes with the view (#2351): the machines'
  copies of one node add up, as each banked its own turns.

### Decisions on slice 3's open questions

- **Decided: a turn with no active link goes under its session's own node, and the
  project's rollup says the sum as `unlinked`.** Because then every turn is somewhere and
  the totals add up to the real spend, and a report can show how much work had no issue.
  Alex can overrule.
- **Decided: a review session's cost is part of the PR's cost.** Because the PR page starts
  a review with `P#n`, a `works-on` link to the PR, and a `reviews` link counts too. Alex
  can overrule.
- **Decided: a helper's own links come before its parent's.** Because the Scrum Master
  starts each lane as its helper, and a lane's cost belongs to the lane's issue, not to
  the Scrum Master's. Alex can overrule.
- **Decided: a merged revert's own cost is waste, and failed CI rounds are a count, not a
  cost.** Because a revert PR says only its title, not which PR it reverts, and no turn
  belongs to a CI round. Alex can overrule.
- **Decided: the milestone rollup reads `part-of` links; the host does not make them from
  the forge yet** (#2935). A person can make one with `lineage/link`. Alex can overrule.

## Reports ▸ Value (#2351)

Slice 4 reads the cost on the links on the control plane, in
`Go/internal/controlplane/reports_value.go` (`reports/value`, capability `reports.value/1`,
`ReportQuery` → `ReportValue`), and draws it as Reports ▸ Value on the Mac window and the web
page.

- **The scope** is Reports': Me, a group or the organisation. The nodes of the scope's
  machines add up: the cost adds, `fixes` and `partOf` join, the newest copy says how a PR
  ended, and the failed checks are the most that any machine heard.
- **The range:** a node counts when its `lastAt` is in it, with all of its cost.
- **The answer:** the work on issues and PRs (`total`), `waste`, `unlinked`, the cost per
  merged PR, the PRs merged, closed and reverted, the failed CI rounds, the median lead time,
  and a row for each issue and milestone with a part in the range, the most costly first, at
  most 100 each.
- **Lead time:** each node now has `firstAt` (when the machine first banked or noted it) and a
  PR `endedAt` (merged or closed). An issue's lead time is from the first `firstAt` of it and
  its PRs to the last `endedAt` of its merged PRs.
- **The Lineage view** (a session's links, and the issue and PR pages) is #2940 and #2941.

## Clients

mac: Reports ▸ Value (#2351), remote: tier mac+web, web: Reports ▸ Value (#2351).
