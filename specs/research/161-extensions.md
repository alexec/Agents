# 161: Extensions as four layers

2026-10-03, branch `agents/research-github-issue-161` off main at 0d235007. Research only; nothing is built.

**Method**: The #161 researcher read issue #161 and the issues it names (#60, #61, #65, #67, #122, #125–127, #138, #146, #147, #159/#160), README, AGENTS.md, `docs/reference/events.md` and `agent-tools.md`, the research notes 060, 099 and 122, specs 059, 060, 073 and 074, and the event and Dashboard code (`AgentsKitCore/Model/Event*.swift`, `AgentsKitCore/Dashboard/*`, the daemon's tile tools, the three `DashboardPage`s). It also read the live tile files in `~/Agents/.agents/dashboard/` and `.agents/workflows/update-dashboard.md`. Two read-only helpers surveyed the Dashboard code and the marketplace, MCP and trust code. Line numbers are at 0d235007.

## Summary

- **An extension is a committed folder of data in the project, `.agents/extensions/<name>/`**: a manifest naming a built-in source adapter, declarative mappings, optional page templates and an optional MCP server entry. No extension code runs.
- **The contract:** sources produce **events, plus snapshots of keyed sets** → the host folds them into **records** (tiles, pinned pages) through **mappings** or the built-in **record tools** → clients draw only records. Presentation never computes from events; storage never calls a source.
- **The event shape needs four things** for outside sources: three-part names (refused today by `Event.swift:137`), text details, a `key` for de-duplication with snapshots for catch-up, and a `source`.
- **Correction to the issue:** tile history is project state, not a host stream. #127 moved it into `.agents/dashboard/history/`. The host-stream side is events, set times and (new) mapping state.
- **The Dashboard fits** once the contract states six things it does today: person fields in a record, a refresh action, a stale clock, host-written `source`, layout as page state, and two writers (§3).
- **GitHub fits** with a three-verb mapping language (`latest`, `count`, `rows`) over collections the adapter keeps (§5). It moves four tiles off the nightly Sonnet turn, losing only the "of N total" unit.
- **Recommendation:** five slices. First, mappings + a `gh` snapshot poller for tiles only. That needs Alex to allow polling before #61 (decision 2).

## 1. The four layers and their contracts

An **extension** is a named bundle that fills some of four layers. Each layer talks only to its neighbours, through one stated shape:

```
 source ──► [1 Ingestion] ──events──► [2 Storage] ──records──► [4 Presentation]
                                        ▲      │
                          tool calls    │      │ reads
                                     [3 Agent tooling]
```

| Pair | Contract (the only thing that crosses) | Who checks it | Today |
|---|---|---|---|
| **1 → 2** Ingestion → storage | An `EventDraft` (`Event.swift:107`): name, scope, checked details, optional text, plus three new fields (§2 Q1): `source`, `key`, and for a poll a **snapshot** of a keyed set. Nothing else enters storage from outside. | The host's `raise` (`DaemonCore+Events.swift:17`) and the catalogue (`EventCatalogue.swift:110`) | Only the app's own events and `custom.*`. No outside source. |
| **2 → 2** Events → state | A **mapping**: a declarative rule, read from a file, that turns matching events into a tile (or other record) the host writes. Uses 073's `EventPattern` (`EventPattern.swift:9`) unchanged for "which events". | The host, when the file is read (refused in words, as a workflow file is) | Missing. Only an agent turns events into tiles. |
| **3 ↔ 2** Agent tooling ↔ storage | Tool calls that write the same records a mapping writes, under the same checks (`TileCheck.swift`), naming a keeper. Agents read with `read_dashboard`. | The host, per call, with the caller's token | `set_tile` / `remove_tile` / `move_tile` / `read_dashboard`, `publish_event`, `show_file`. Built in. |
| **2 → 4** Storage → presentation | **Records with a fixed type**: a `TileFile` (`Tile.swift:12`) of type number, status, table, note or link, or a project file opened as a page (Markdown live doc, HTML #67). Clients never see events-to-tile logic or raw source data. | Each client draws only the known types; unknown types draw as "needs a newer app" | Tiles reach the clients over `DashboardWire.swift`; files over `files/*`. |

What a layer may **not** do, which is what keeps them swappable:

| Rule | Why |
|---|---|
| Presentation never reads events to compute a value. | One computation, on the host, the same for Mac, Remote and web (parity rule, AGENTS.md). |
| Storage never calls a source. | Polling is ingestion; a tile that "runs `gh`" is the hole 122 §3 option D/E rejected. |
| Ingestion never writes a tile. | Every write to a record goes through the mapping or a tool, so it has a keeper and passes `TileCheck`. |
| Agent tooling never writes a file in `.agents/dashboard/` directly. | Already the rule (122 §3, briefing). |

## 2. The seven questions

### Q1. Events as the spine

**Yes: every source reduces to "produces events", with four additions to the shape (three-part names, text details, a key with snapshots, a source).** Storage and presentation then depend only on events and records.

| Source | Becomes events how | Fits today's shape? |
|---|---|---|
| Agent tool call (`publish_event`) | Already does (`custom.*`) | Yes |
| App's own changes (agent, workflow, branch, lease, mac) | Already do (`EventCatalogue`) | Yes |
| File watch (`.agents/workflows/`, `.agents/dashboard/`) | Does **not**: the host re-reads the files directly. It need not become events: a file is *state*, read by storage, not a happening. | Not needed (see Q3) |
| Webhook (control plane, after #61) | Control plane checks the signature, normalises to an envelope `{source, kind, id, checked, text}`, forwards to hosts (060 §4) | Needs `source`, 3-part names, text details |
| Polling (`gh`, Jira REST) | Diff against the last seen list, raise what changed; the first poll only seeds (042 FR-014, removed `DaemonCore+PullRequestEvents.swift`) | Needs `key`, and a **snapshot** for seeding and catch-up |
| Slack Socket Mode | Each socket message is one event (060 §2 E) | Needs `source`, text details |
| MCP events (#65) | A notification from a subscribed server → one event | Closed with no SEP (060 §0); same shape as a webhook if it lands |

**What the event shape lacks** (every gap is in `AgentsKitCore/Model/Event.swift` or `EventCatalogue.swift`):

| Gap | Today | Needed for |
|---|---|---|
| **Three-part names** | `isWellFormed` is `^[a-z][a-z_]*\.[a-z][a-z0-9_]*$` (`Event.swift:137`): `github.pull_request.opened` is refused. `EventSubject` is a closed enum (`EventCatalogue.swift:4`). | Any outside source; 060 §4 wants `prefix.*` |
| **Outside text** | Details are `[String: String]`, ≤ 10 and ≤ 200 chars (`Event.swift:132-133`); no `isText` on `EventDetail` (`EventDetail.swift:9`) | Titles: shown in a table, never matched, fenced for agents (060 §3, Alex's #60 answer 3) |
| **Identity (`key`) and de-duplication** | None. Repeats fold only when the *last* event is equal within 60 s (`EventLog.swift:19, 46`) | A webhook and a poll seeing the same change raise it once; a mapping keeps a set keyed by `repo#number` |
| **Snapshots** | Events are deltas only | A poll must be able to say "the open PRs are exactly these" so a count can be reseeded after a sleeping host or a missed webhook. Without it a count drifts for ever. |
| `source` / `from` | `publisher` is an agent only (`Event.swift:25`) | Provenance on the tile ("kept by GitHub"), refusing strangers (060 §3) |
| Retention as a store | 7 days or 10,000 (`EventLog.swift:21-23`) | Not a gap if mappings fold events into state **as they arrive** (122 §3 C says the same); never replay the log to rebuild a tile |

A **snapshot** is not an event on the log. It is a second message from ingestion to storage, `{source, collection, items: [{key, checked, text}]}`, that replaces a keyed set; the host raises the events that the difference implies (as 042's poll did), so waits and workflows still see deltas. This keeps the Events page free of one row per open PR every poll.

### Q2. Agents optional: declarative mappings

Today every GitHub tile costs a Sonnet turn a night (`.agents/workflows/update-dashboard.md:1-14`), runs seven shell commands the agent might misread, and is up to 24 h old. The four GitHub tiles are pure functions of GitHub state, so they need no judgement. `not_shipped` and `runtime_check` read local files, and `issues_in_flight` is the lead's own view: those stay with agents.

The smallest language that covers the GitHub tiles has **three verbs** and no expressions (§5). It reuses `EventPattern` for matching, so every rule 073 checks (unknown detail, wrong value) is refused the same way.

### Q3. Two kinds of storage

The split holds, with **one correction: tile history is already project state.** #127 (closed) moved points from `<root>/dashboards/<key>/points/` to `.agents/dashboard/history/<id>.jsonl` in the project (`agent-tools.md:38`; live in `~/Agents/.agents/dashboard/history/`).

| Piece | Kind | Where | Evidence |
|---|---|---|---|
| Tile definition + value | Project state | `.agents/dashboard/<id>.json` | 074 data-model; `Tile.swift:12` |
| Tile history (numbers) | Project state (**not** a host stream) | `.agents/dashboard/history/<id>.jsonl` | #127; `TileLimits.historyBytes` 8 MB (`Tile.swift:211`) |
| Order | Project state | `.agents/dashboard/_order.json` | #147; `DashboardOrder.swift:21` |
| Hide | Project state | `hidden` in the tile file | `Tile.swift:21-23` |
| Limits, switches | Project state | `.agents/project.json`, workflow front matter | #125, #126 |
| Pins (#159) | Project state | `.agents/pins.json` `{pins:[{path, title?, pinned_by}]}` (#160 had proposed `project.json`) | branch `agents/build-github-issue-159`, not on main |
| Live docs, HTML pages | Project state | ordinary project files | #67 |
| Workflows | Project state | `.agents/workflows/*.md` | 008 |
| Events | Host stream | `<root>/…/events.jsonl` | `StoreLocations.swift`, `EventStore.swift` |
| Set times, keeper changes, removals | Host stream | `<root>/dashboards/<fnv16(path)>/state.json` | `DashboardStore.swift:15-17,366-395`; a clone shows "age unknown" (`DashboardWire.swift:145-150`) |
| **Mapping state** (keyed sets) | Host stream, **rebuildable** | beside the events | new: rebuilt from the next snapshot, so it need not move with #61 |
| **Extension definition** (manifest, mappings, page templates) | Project state | `.agents/extensions/<name>/` | new (Q7) |
| **Secrets** | Neither | control plane secret store, or the host's Keychain | Q6 |

Rule for an extension: **a record a person reads is project state; anything rebuildable from a source is a host stream.** History is the case where Alex chose portability over churn (#127), which the rule allows because a trend can't be rebuilt from GitHub.

### Q4. Two kinds of presentation

**Yes.** Both already exist; what is missing is letting anything but the Dashboard use them.

| | Native building blocks (tiles) | HTML page (#67) |
|---|---|---|
| Types | number, status, table, note, link (`Tile.swift:76-78`); `page` on the #159 branch | `.html` / `.htm` (`AgentsKitCore/Files/HTMLPage.swift:16-49`) |
| Drawn by | `TileCard` + `Sparkline`, shared by Mac and Remote (`Shared/UI/Dashboard/TileCard.swift:7-240`); web by hand (`Web/src/views/Dashboard.tsx:22-344`, `model/dashboard.ts`) | WKWebView with a non-persistent store, `agents-page://` served by `files/read`, scripts off per load, a content rule blocking network, no popups (`Shared/UI/Page/HTMLPage.swift:89-157, 187, 202`) |
| Clients | Mac, Remote, web | Mac and Remote; **the web page doesn't render HTML** |
| Accessibility, light/dark, phone layout | Yes (`TileCard.swift:28,43-44,93,104`; Remote one column, tables cut to 5 rows) | Whatever the page's author wrote |
| Reusable outside the Dashboard? | `TileCard` takes a `TileView` and callbacks, so yes; the page, sections and order are tied to `DashboardSnapshot` | Yes: any project file, via Files or `show_file` |
| Data-driven? | Yes, from a record | **No.** Scripts are off and there's no network, so a page can't fetch data. The host has to write the data *into* the file. |

Two consequences for extensions:
- **A tile is a record anyone may keep**, not a Dashboard feature. It needs a third keeper kind, `{extension: <name>}` (today `agent` or `workflow` only, `Tile.swift:81-102`), and a place to show other than the Dashboard: #159's pinned pages and its `page` tile already give that.
- **An extension's page is a file the host renders**, from the same records a mapping keeps, through a template with no scripts. It's then pinned (#159) and opened like any HTML page. The S20261002-2 finding (scripts on, a click can send files out) argues against giving extension pages scripts.

### Q5. Agent tooling via MCP

**Yes, for the extension's own tools; no, for records.** 060 already installs MCP servers per project (`.agents/mcp.json`, approval by digest in `<root>/mcp-approvals.json`, `Catalog/MCPApprovals.swift:3-40`) and per person, and merges them into each session (`DaemonCore+SessionServers.swift:26-58`). An extension that wants agents to act on its source (comment on a PR, re-run CI) names an MCP server entry, which goes through that path unchanged. The GitHub case needs none: agents already have `gh`.

The app's own tools (`AppTool.swift:17-100`, served by `AppService.swift:548-573`) stay built in, because each one writes host state that only the host can check:

| Stays built in | Why |
|---|---|
| `finish_turn`, `ask_form`, `show_file` | The turn and the window |
| `start_agent` … `archive_agent`, `list_my_agents`, `list_sessions`, `read_session` | Agent lifecycle |
| `lease_resource`, `release_resource`, `list_resources` | Shared resources |
| `wait_for_event`, `cancel_wait`, `publish_event` | The event spine |
| `manage_workflows` | Approval |
| `set_tile`, `remove_tile`, `read_dashboard`, `move_tile` (and #159's `pin_page`, `unpin_page`, `move_pin`) | **Records**: a keeper, `TileCheck` and atomic writes. These become *generic* record tools, not Dashboard tools. An extension never gets tools of its own here. |

Found on the way: `move_tile` is served (`AppService.swift:565`) but not in `AppTool.all` (`AppTool.swift:111-116`), so `isServedByTheApp` is false for it. That's a small bug, worth an issue.

**MCP events (#65)** are closed, with no code and no research note (the app's server drains notifications, `AppService.swift:238-241`). If they land, they're one more ingestion adapter producing the same envelope.

### Q6. Trust

| Piece | Runs where | What it may do | Gate |
|---|---|---|---|
| Ingestion adapter (GitHub, later Slack and Jira) | **Code in the app**, never in the extension. Webhooks on the control plane (after #61); polling and sockets on the host that holds the project | Read the source with the person's own sign-in (`gh`) or a token; produce envelopes | Built in, reviewed as app code; #42's public-surface list for `/v1/hooks/*` (060 §3) |
| Mappings | Host | Write records the extension keeps, nothing else | Declarative: parsed and checked like a workflow file; a new or changed file waits for approval by digest (`DaemonCore+WorkflowApproval.swift:3-66`) |
| Page templates | Host renders; client shows with scripts off and no network | Show records | Same approval; no scripts |
| MCP server (optional) | The runtime, inside the agent's sandbox | Whatever the server does | 060's approval by digest; secrets as `${NAME}` |
| Workflows triggered by outside events | Host | Start agents | Alex's #60 answers: only people with access may trigger; text fenced as data |

**No extension code runs in v1.** An extension is data: a manifest, mappings, templates and an optional MCP entry. The adapters are a fixed, built-in set. A host-run command source was rejected in 122 §3 E for the S2/S3 reason, and nothing here changes that.

**Secrets:**

| Secret | Where |
|---|---|
| Webhook signing secret, GitHub App key | Control plane's secret store; shown once, never logged; hosts get only the normalised envelope (060 §3) |
| GitHub polling | `gh`'s own sign-in; the app stores nothing |
| Slack and Jira tokens | Host credential store (Keychain on a Mac), held by the daemon, never in agents' environments |
| MCP server secrets | 060's `~/.agents/secrets.env`, plaintext 0600 (`Catalog/SecretsEnv.swift:1-20`). Weaker than the Keychain, and S20261002-3 (an entry can draw another server's secret) applies. Fix before extensions lean on it. |
| In the extension folder | **Never.** It's committed. The manifest names a secret (`${GITHUB_WEBHOOK}`); it never holds one. |

### Q7. Packaging and scope

**An extension is a folder in the project, `.agents/extensions/<name>/`, committed, like `.agents/workflows/` and `.agents/skills/`.** It moves with the project (#61), and every client sees it the same way (one grant for every client, #111: no operator-only settings).

```
.agents/extensions/github/
  extension.yaml     # name, source adapter + its settings, which collections it keeps
  tiles.yaml         # mappings (§5)
  pages/prs.html.t   # optional page template
```

| Question | Answer |
|---|---|
| Project, host or control plane? | **Project** for the definition. The host runs the mappings for the projects it holds. The control plane only receives and forwards webhooks; it learns no extension (060 §2: broadcast the envelope, each host matches its projects). |
| Plugins and the marketplace | A plugin (`.agents/plugins/<p>`, `DotAgents+Plugins.swift:3-44`) is for a *runtime*: skills, commands, MCP servers handed to Claude/Codex/Gemini. An extension is for *the app*: records and pages. They meet where an extension names an MCP server. The 059 sheet can list extensions later, installed into `.agents/extensions/` with 059's lock and pinned commit; no catalogue is needed for slice 1. |
| Built-in extensions | The Dashboard (§3) is the reference one, built in. GitHub ships as a folder the app can write with one click, so it's visible, diffable and removable. |
| Two clones, two hosts | Each host holding a clone runs its mappings into that clone's tile files. The control plane's broadcast and the host's de-duplication (`key`) keep that correct. |

## 3. Test case: the Dashboard in four layers

| Layer | App provides (any extension) | Dashboard adds (its own) |
|---|---|---|
| 1 Ingestion | `set_tile` calls; folder watch of `.agents/dashboard/` (`DaemonCore+Dashboard.swift:315-343`); outside-edit hash (`:244`) | **Update now** (`dashboard/update`, `DaemonCore+DashboardUpdate.swift:11-109`): runs the workflow labelled `dashboard` or a one-off agent, 5-minute cooldown (`DashboardUpdate.swift:45`). The nightly workflow (#138). |
| 2 Storage | Tile file + `TileCheck` + limits (`Tile.swift:195-219`); history with 7 d hourly / 90 d daily (`DashboardStore.swift:185-281`); keeper, take-over, removal memory (`DashboardStore.swift:366-395`); stale clock | `_order.json` sections and order (`DashboardOrder.swift:3-23`); `hidden`; 60 tiles per project |
| 3 Agent tooling | `set_tile`, `remove_tile`, `read_dashboard` (generic record tools) | `move_tile` (order is the Dashboard's) |
| 4 Presentation | `TileCard`, `Sparkline`, web tile; `DashboardModel` (stale, ▲▼) | One page per project (`SidebarItem.swift:12`); summary row (`DashboardModel.swift:130-143`); drag and Move menus; Hide/Show/Remove; empty states; footer; keeper foot |

**What the contract can't yet express, and the fix:**

| Lost | Why | Fix in the contract |
|---|---|---|
| A person's override in an agent's record (`hidden`; Remove undone by the next set, `DaemonCore+Dashboard.swift:89-93`) | The contract has one writer per record | Records carry **person fields** (`hidden`, position) that no keeper may write. Already true in code; state it. |
| Update now runs an agent | Ingestion was "events in". Here a button starts a turn. | A **refresh action** in the manifest: `refresh: workflow <id>` or `refresh: poll`. For GitHub tiles, Update now becomes "poll now", free. |
| Staleness on the host's clock | Not derivable from events | Part of the record contract: `stale_after_hours` + the host's set time. A mapping tile's set time is its last event or snapshot. |
| `source` is a command an agent re-runs | Prose, not schema | A mapping tile's `source` is written by the host ("GitHub, via gh as alexec, 3 Oct 14:05"), never re-run. |
| Order shared by people and agents | Layout, not data | The page owns layout (`_order.json`); it is presentation state, kept in the project. |
| Notes and status lines are prose | Not from events | Agent-kept tiles stay agent-kept. The contract has two writers, tools and mappings, and the Dashboard needs both. |

With these six stated, the Dashboard is expressible without loss: **a built-in page over the project's tile records, plus layout state and a refresh action.**

## 4. Test case: GitHub end to end

| Layer | Piece | Detail |
|---|---|---|
| 1 Ingestion | **Webhook** (after #61) | GitHub App via the manifest flow; `/v1/hooks/github/<id>` on the control plane; HMAC over raw bytes, de-dup on body hash 7 days; normalise to envelope; broadcast to hosts; hold 24 h for an offline host (060 §2–§4) |
| | **`gh` poll** (catch-up) | On the host holding the project, only while the extension is enabled there: every 30 min with webhooks, every 15 min before them, and on `mac.wake` and Update now. `gh api` with `If-None-Match` (304s are free). Produces **snapshots** of `open_pull_requests` and `open_issues`, and the newest `checks` on main |
| | Events | `github.pull_request.{opened,merged,closed}`, `github.issue.{opened,labelled,closed}`, `github.checks.completed` (060 §4 table), raised from webhooks or from snapshot differences, de-duplicated by `key` |
| 2 Storage | Host stream | The keyed sets (rebuilt from the next snapshot) |
| | Project state | `.agents/extensions/github/*`; tile files `ci_status`, `open_prs`, `open_bugs`, `github_issues`, keeper `{extension: github}`; their history |
| 3 Agent tooling | None new | Agents read with `read_dashboard`; act with `gh`. Optional later: a GitHub MCP server entry from the registry (060) |
| 4 Presentation | Tiles | Drawn as now, on all three clients. Keeper foot reads "GitHub" with the last poll or delivery |
| | Page (optional) | `pages/prs.html.t` rendered to `.agents/extensions/github/out/prs.html` from `open_pull_requests`, pinned (#159). Text cells (titles) escaped. Mac and Remote only until the web renders HTML |

The four tiles, as mappings (§5), replace rows 43–46 of `update-dashboard.md`. The workflow keeps `total_commits`, `not_shipped` and `runtime_check`.

## 5. The mapping language

**Three verbs, one filter, one template.** No arithmetic, no conditionals beyond a value table, no loops outside `rows`.

| Element | Meaning | Reuses |
|---|---|---|
| `latest: <event pattern>` | The tile shows fields from the newest matching event | `EventPattern.parse` (073): a wrong detail or value is refused in words |
| `count: <collection>` | A number tile: how many items in a keyed set | — |
| `rows: <collection>` | A table tile: one row per item, `columns`, `sort`, `limit` ≤ 50 | `TileLimits.tableRows` |
| `where: {detail: value \| [any of]}` | Narrows the events or items | `DetailFilter` (`labels` is a set) |
| `"{detail}"` | Text from a checked detail, or `{at}`; text details only in tile cells, escaped | — |
| `{detail: {code: value, else: value}}` | A value table, e.g. a conclusion → a level | — |

A **collection** is declared by the adapter, not the mapping (`github.open_pull_requests`, `github.open_issues`): the adapter knows that `merged` removes a PR. That keeps the language free of add and remove rules.

```yaml
# .agents/extensions/github/tiles.yaml
ci_status:
  title: CI on main
  type: status
  section: Delivery
  stale_after_hours: 30
  latest: github.checks.completed
  where: { branch: main, name: ci }
  status:
    level: { conclusion: { success: ok, failure: bad, else: warn } }
    line: "{conclusion} at {head}"
    since: "{at}"

open_prs:
  title: Open pull requests
  type: number
  section: Delivery
  count: github.open_pull_requests
  number: { unit: PRs, good: down }

open_bugs:
  title: Open bugs
  type: number
  section: Project
  count: github.open_issues
  where: { labels: bug }
  number: { good: down }

github_issues:
  title: Open issues
  type: number
  section: Project
  count: github.open_issues
  number: { good: down }

prs_table:               # an example of rows; not one of today's tiles
  title: Pull requests
  type: table
  rows: github.open_pull_requests
  columns:
    PR: { text: "#{number} {title}", url: "{url}" }
    Author: "{author}"
    CI: "{checks}"
  sort: -updated
  limit: 20
```

**Lost against today's tiles:** `github_issues`'s unit "of N total" needs a count of *all* issues, which isn't a collection. Drop the unit, or add a `github.all_issues` count to the adapter. Nothing else is lost.

**Left out on purpose:** sums, ratios and time windows ("PRs merged this week"). They'd turn this into an expression language, which 099 recommended against for filters. 122's slice 2, "counted from events per hour/day", can be a fourth verb, `per: day`, later.

## 6. Recommendation

**Adopt the four-layer contract, with events + snapshots as the only way in, records (tiles and pinned pages) as the only way out, and declarative mappings plus the built-in record tools as the two writers.** Extensions are committed folders of data. The only code is the app's own fixed adapters.

| # | Slice (one lane each, in order) | Proves | Web parity |
|---|---|---|---|
| 1 | **Mappings + extension keeper + a `gh` snapshot poller, tiles only.** `.agents/extensions/github/` with `latest` / `count`, keeper `{extension}`, approval by digest, Update now = poll now for those tiles. Move `ci_status`, `open_prs`, `open_bugs`, `github_issues` off the nightly workflow. **No outside events** reach waits or workflows. | Agents optional; the GitHub tiles cost no turns | Keeper foot "GitHub" on all three |
| 2 | **Event shape for outside sources.** Three-part names and `prefix.*`, `EventDetail.isText`, `key` de-dup, `source`/`from`, snapshot → delta events. GitHub events visible on the Events page, in waits and in workflows with the `from` default. *Held until #61 if Alex's #60 answer 1 stands.* | Events as the spine | Events-page capsule |
| 3 | **Tiles outside the Dashboard, and extension pages.** A pinned page (#159) can show tiles or a host-rendered template; `rows` verb; `prs.html`. Builds on #159 merging. | Two kinds of presentation | Web has no HTML page: parity issue |
| 4 | **Webhooks on the control plane** (060 slice 3, after #61): GitHub App, envelope forwarding, 24 h hold; the poller drops to a 30-minute catch-up. | Fast, with polling as catch-up | none |
| 5 | **Extensions in the marketplace sheet** (059's lock files), plus an optional MCP entry per extension through 060. Secrets for MCP move off plaintext `secrets.env` first (S20261002-3). | Packaging | Sheet on web |

Small, separate: file the `move_tile` / `AppTool.all` bug (Q5).

## 7. Decisions for Alex

| # | Decision | Recommendation |
|---|---|---|
| 1 | Adopt the contract: events + snapshots in, records out, mappings and record tools as the writers | Yes |
| 2 | **Slice 1 polls GitHub with `gh` on the host before #61**, for tiles only, with no events to agents. Alex's #60 answer 1 said no outside events before #61; this reads GitHub without raising events or starting agents. Allowed? | Yes: the risks behind that answer (strangers triggering agents, injected text) don't arise when nothing reaches an agent |
| 3 | Extensions live in the project (`.agents/extensions/<name>/`), committed, and are data only, with no extension code | Yes |
| 4 | New or changed mapping files wait for approval, as workflow files do | Yes; the GitHub folder the app writes itself arrives approved |
| 5 | Mapping language: three verbs (`latest`, `count`, `rows`), no expressions; collections defined by adapters | Yes |
| 6 | Keep `github_issues`'s "of N total" (adds an all-issues count) or drop it | Drop |
| 7 | Extension pages: host-rendered templates with scripts off, rather than scripts-on pages fed data | Templates |
| 8 | Mapping state (keyed sets) is a host stream, rebuilt by the next poll, not moved with the project | Yes |
