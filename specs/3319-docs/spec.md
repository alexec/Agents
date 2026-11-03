# Docs, first-class beside Work (#3319)

Work made issues and pull requests first-class: a menu item, lists across folders and
forges, a page for each, lineage on top and actions (#3100). The requirements and
designs behind that work are the other half of what an agent works from (#3248). This
spec gives docs the same place: a **Docs** item in the left menu, below Work.

Alex chose this on 2026-11-02, over a Docs section on Work's pages only, or waiting.

Tier: **Mac + web**, as Work. The Remote does not have it (`remote: tier mac+web`).

## Sources

A doc comes from one source. The list groups the docs by source.

| Source | What it holds | How the daemon reads it |
|---|---|---|
| **A folder** | the `*.md` files at its top, and under `specs/` and `docs/` | the file system, with the bounded walk of the Docs slot (`docsScanLimit`) |
| **A docs connector** | Confluence, Notion, Google Drive, or any docs server in the Docs slot | its map in `.agents/docs-maps.json` (#3307), through the daemon's MCP client |

- A folder whose Docs slot is **None** gives no source.
- A connector with no map shows as a source that is "not mapped", with **Map it…**,
  which starts the `map-a-docs-server` skill.
- Each machine reads its own folders and connectors. The clients merge the machines, as
  Work does. One connector on two machines is one source: the client keeps the first.

## A doc's ref

Each doc has a ref, as an issue or a PR has one. It is a lineage ref (#2348):
`<scheme>:<id>`, kind `doc`. The list, the page, the wire, the agent tools, lineage and
links all use the same ref.

| Source | Ref | Example |
|---|---|---|
| A folder doc in a repo | `<forge>:<owner>/<repo>/doc/<path>` | `github:alexec/agents/doc/specs/3319-docs/spec.md` |
| A folder doc with no forge remote | `folder:<machine>/<folder name>/doc/<path>` | `folder:studio/notes/doc/docs/plan.md` |
| Confluence | `confluence:<site>/<page id>` | `confluence:acme.atlassian.net/123456` |
| Notion | `notion:<page id>` | `notion:1f2e3d4c…` |
| Google Drive | `gdrive:<file id>` | `gdrive:1AbC…` |
| Any other mapped server | `mcp:<server name>/<its id>` | `mcp:wiki/handbook-42` |

- **The repo part is the same as for issues:** the folder's `origin` remote, in lower
  case. The path keeps its case, because file names are case-sensitive. So a doc has one
  ref on every machine and in every worktree, as its issues do.
- **A path ref follows the path.** A doc that moves gets a new ref. Its old lineage
  stays on the old ref. This is the same as for a file in git. Find renames later, if
  people need it.
- **The short form** is the path for a folder doc (`specs/3319-docs/spec.md`) and the
  title for a connector doc. Rows, page titles and Lineage use the short form. The full
  ref is in the tooltip and in **Copy ref**.
- **Its address:** `#/docs/<ref>` on the web page, and `agents://docs/<ref>` for the
  Mac window. **Copy link** copies the address. A ref or an address pasted in a prompt, an
  issue or a PR body names the doc.
- **A session label:** `doc:<short form>` names the doc that a session works from, as
  `#<n>` names its issue. *Build this* sets it. Lineage reads it as a `works-on` link to
  the doc (#3308).

## The wire

Three methods on the daemon. The agent tools of #3317 use the same code.

- `docs/list { folder?, source?, cursor? }` gives the docs of a source: ref, title,
  source, path or URL, updated. A connector's list is its search for the empty query,
  or its "recent" tool when the map has one.
- `docs/search { query, sources?, limit? }` gives results with matches: `line` and a
  snippet for a folder doc; a snippet only for a connector doc (#3317).
- `docs/read { ref, from?, to? }` gives the Markdown text with its total `lines`. A
  connector doc is turned into Markdown in one way only.

Every method is bounded: a result limit, a byte limit for each read, a timeout for each
connector. A source that fails is named in the result. It does not fail the rest.

## The list

```
┌ Sidebar ──────────┐┌ Docs ──────────────────────────────────────────────────────┐
│ + New Session     ││ [⌕ Search docs                    ]  Source: All ▾  Sort ▾ │
│ ☑ Work            ││                                                            │
│ ▤ Docs        ◀── ││ AGENTS (this Mac)                                          │
│                   ││   ▸ specs/                                                 │
│ Status            ││       3319-docs/spec.md       Docs, first-class…   2h ago  │
│   Events          ││       3265-work-plans/spec.md Plans in Work         1d ago  │
│   …               ││   ▸ docs/                                                  │
│                   ││       explanation/leases.md   Leases               3d ago  │
│ Folders           ││   README.md                   Agents               5d ago  │
│   Agents          ││                                                            │
│   …               ││ CONFLUENCE  (acme.atlassian.net)                           │
│                   ││   Payments: requirements                           1w ago  │
│                   ││   Checkout redesign                                2w ago  │
│                   ││                                                            │
│                   ││ NOTION — not mapped              [Map it…]                 │
└───────────────────┘└────────────────────────────────────────────────────────────┘
```

- **Sort:** Last updated (default), Title.
- **Source:** All, or one folder or connector.
- **Search:** with a query, the list becomes results. A row shows each match under the
  doc's title: the line number and the snippet for a folder doc, the snippet for a
  connector doc. A click on a match opens the page at that line.
- A doc that lineage knows shows its cost and its sessions at the right of its row,
  as a Work row does (after #3308).

## A doc's page

```
┌ Docs ▸ Agents ▸ specs/3319-docs/spec.md ───────────────────────────────────────────┐
│ Docs, first-class beside Work                                                     │
│ github:alexec/agents/doc/specs/3319-docs/spec.md · updated 2h ago               │
│ [Start Agent ▾]  [Open in Files]  [Copy link] [Copy ref]                                │
│                                                                                   │
│ ┌ Lineage ───────────────────────────────────────────────────────────────────┐   │
│ │ Read by 3 sessions · built 2 issues, 1 PR merged      · $4.10          │   │
│ └────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                   │
│  The rendered Markdown, live, as the Files pane draws it.                         │
│  …                                                                                │
└───────────────────────────────────────────────────────────────────────────────────┘
```

- **The text:** a folder doc is the Files pane's Markdown page (`FilesPane.swift`),
  and it is live. A connector doc is the Markdown from `docs/read`, with
  **Open in Confluence** (or the vendor's name) in place of **Open in Files**.
- **Start Agent ▾:** *Build this* (a new session in the doc's folder, its prompt the
  doc's ref and "build what this describes"), *Review this* (find what is missing or
  wrong, and file it), and *Ask about this*. The session has `docs_read` on the doc.
  A connector doc asks for the folder to start in.
- **Lineage:** the sessions that read the doc, the issues and PRs they made, and what
  they cost (#3308). A doc that no session has read shows no Lineage box.
- **Read only.** A local doc is edited by an agent or in the person's editor; a
  connector doc in the vendor's app (#3248).

## Docs in Work

An issue's and a PR's page in Work gets a **Docs** section: the docs that the item
links to, then the top three `docs/search` results for its title. Each opens the doc's
page. This is part of the Start Agent story (step 3), so the two link both ways.

## Steps

The sub-issues of #3319 and their "blocked by" links are the plan.

| Step | Issue | What | UI |
|---|---|---|---|
| 1 | #3320 | `docs/list`, `docs/search`, `docs/read` on the wire and in the daemon | no |
| 2 | #3317 | the agent tools over step 1 | no |
| 2 | #3321 | the Docs list and a doc's page, read only | Mac + web, `needs-approval` |
| 3 | #3322 | Start Agent on a doc, and the Docs section on Work's pages | Mac + web, `needs-approval` |
| 3 | #3308 | a doc in lineage; its Lineage box on the doc's page | Mac + web |

## Open questions

- Does Docs show every `*.md` file under `specs/` and `docs/`? Recommended: yes,
  grouped by folder and subfolder, until a folder asks for less (a `docs` key in
  `.agents/folder.json`).
- Does a folder with no docs connector still get Docs? Recommended: yes; its own docs
  are a source.
- Does a connector list all its docs, or only search? Recommended: its recent docs when
  the map has a tool for them, else only search, and the source says so.
