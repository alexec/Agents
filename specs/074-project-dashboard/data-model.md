# Data model: Project Dashboard, slice 1

## Tile file — `<project>/.agents/dashboard/<id>.json` (committed)

```json
{
  "hidden": false,
  "keeper": { "agent": "6F0C…" },
  "number": { "good": "down", "unit": "", "value": 4 },
  "section": "Quality",
  "source": "gh issue list -l bug --state open",
  "stale_after_hours": 24,
  "title": "Open bugs",
  "type": "number"
}
```

| Field | Rule |
|---|---|
| id | the file name: `[a-z0-9_-]{1,40}` |
| title | 1–80 characters |
| type | `number`, `status`, `table`, `note`, `link` |
| section | optional, up to 40 characters |
| keeper | `{"agent": uuid}` or `{"workflow": id}` |
| source | required for number and table, up to 200 characters |
| stale_after_hours | 1–168, default 24 |
| hidden | the person's Hide |
| number | `value` (finite), `unit` (≤ 12), `good` (`up`, `down`, none) |
| status | `level` (`ok`, `warn`, `bad`, `unknown`), `line` (≤ 200), `since` (≤ 40, optional) |
| table | `columns` (1–6 strings), `rows` (≤ 50, each as many cells as columns); a cell is a string or `{"text", "url"}`, ≤ 200 characters |
| note | `markdown`, ≤ 4096 bytes |
| link | `title` and one of `url`, `session` (uuid), `file` (project-relative path), `workflow` (id) |

The whole file is at most 8 KB. No timestamps, no points.

## Host state — `<root>/dashboards/<key>/state.json`

```json
{
  "folder": "/Users/…/Agents",
  "tiles": {
    "open_bugs": { "made": 1759400000, "set": 1759410000, "hash": "ab12…",
                   "keeperChanges": [{ "at": 1759409000, "from": "agent 6F0C…", "to": "workflow nightly" }] }
  },
  "removals": { "lanes": { "at": 1759411000, "by": "the person, on the Mac" } },
  "sets": { "<agent uuid>": [1759410000, …] }
}
```

`points/<id>.jsonl`: `{"t": 1759410000, "v": 4}` per line, number tiles only.

## Wire — `dashboard/get` → `DashboardSnapshot`

| Type | Fields |
|---|---|
| `DashboardSnapshot` | `folder`, `tiles: [TileView]` (hidden ones included, flagged), `now` |
| `TileView` | `id`, `tile: TileFile?` (nil when broken), `problem: String?`, `made: Date?`, `setAt: Date?`, `keeper: KeeperView`, `changedOutside: Bool`, `points: [TilePoint]` (≤ 120, 30 days), `recent: [TilePoint]` (last 10), `keeperChanges: [KeeperChange]` |
| `KeeperView` | `kind` (`agent`, `workflow`), `id`, `name`, `state` (`active`, `archived`, `retired`, `unknown`) |
| `TilePoint` | `at: Date`, `value: Double` |
| `DashboardSummary` | `folder`, `tiles` (shown count), `bad` (live bad count), `line` (the row's one-liner) |

## Derived (AgentsKitCore `DashboardModel`, mirrored in `Web/src/model/dashboard.ts`)

- **stale**: `setAt == nil` (a clone) or `now − setAt > stale_after_hours`.
- **shown level**: a stale status is `unknown`.
- **age words**: "just now", "12 min ago", "3 h ago", "2 days old" (stale), "age unknown".
- **change**: value − the last point at least 24 h old, or the first point when none is.
- **row line**: worst live status ("1 needs a look" for bad, "1 to watch" for warn) · first live
  number tile ("Open bugs 4").
- **sections**: in order of their first tile's `made`; tiles within by `made`, then id.
