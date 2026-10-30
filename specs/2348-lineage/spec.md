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

## Clients

mac: no UI, remote: no UI, web: no UI (the view is #2351).
