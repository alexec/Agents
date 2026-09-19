# Contract: what the app asks the daemon about projects

The same JSON-RPC over the same Unix socket. Four new methods and one new notification. No existing
method changes shape or behaviour.

## Methods

### `projects/list`

**Params**: `{ "includeArchived": true }` — optional, defaults to `true`, matching `agents/list`.

**Returns**: `[ProjectSummary]`, ordered by `lastActivityAt` descending, with `name` already
disambiguated across the whole returned set and `exists` stamped at call time.

```json
[
  {
    "project": { "folder": "file:///Users/alex/work/api", "addedAt": "2026-09-01T09:00:00.000Z" },
    "name": "api",
    "exists": true,
    "lastActivityAt": "2026-09-18T14:02:11.004Z",
    "counts": { "needsInput": 1, "working": 2, "completed": 7, "archived": 12 },
    "leadID": "6B1C9E2A-6C1E-4E2E-9E6B-2A6C1E4E2E9E",
    "leadNeedsInput": false
  }
]
```

The list is the union of every distinct agent `cwd` and every stored record (research §1). A folder
with agents and no record appears with `addedAt` equal to its oldest agent's `createdAt`.

`counts` covers workers only; the lead is reported separately by `leadID` and `leadNeedsInput`,
because it sits in no group (FR-043).

**Side effect, and the only one in this contract**: a project with no lead gets one here — an agent
record with `role: .lead`, no runtime session, nothing spent. This is the one call every window makes,
so it is the one place that can promise FR-035 (research §13). It broadcasts `agent/changed` for the
new lead like any other agent appearing.

### `projects/add`

**Params**: `{ "folder": "file:///Users/alex/work/api" }`

**Returns**: the `ProjectSummary` for it.

Standardises the folder, makes a record if there is not one, and broadcasts `project/changed`. Adding
a folder that is already a project is not an error: it returns the existing summary unchanged, so two
windows racing settle on the same thing.

**Fails**: `folderGone` when the directory does not exist — the same code `agents/start` already
throws for the same condition. Adding a project by hand is the one place the folder must be there:
the user just picked it.

### `projects/archive`

**Params**: `{ "folder": "file:///Users/alex/side/toy" }`

**Returns**: the `ProjectSummary`, now archived.

**Fails**: `projectHasLiveAgents` when any agent in the folder is `running` or `waitingOnUser` — the
lead included, named as "the project lead" rather than by its title. The message names them:
*"Stop these first: the project lead, Fix the parser."* This is deliberately unlike `agents/archive`,
which stops the one agent it was given (research §5).

Archiving does not touch the workers. Their own states and `archivedReason` are untouched, so
unarchiving restores exactly what was there (FR-011).

The lead is the exception, and the only one: it is archived with the project and unarchived with it,
because it cannot be archived alone (FR-046, FR-048). Its transcript is untouched either way.

### `projects/unarchive`

**Params**: `{ "folder": "file:///Users/alex/side/toy" }`

**Returns**: the `ProjectSummary`, now live.

Clears `archivedAt`. Succeeds whether or not the directory still exists — the agents and their
transcripts are the point, and `exists: false` says the rest.

## Notification

### `project/changed`

**Params**: one `ProjectSummary`.

Broadcast on add, archive, unarchive, and whenever an agent change moves a project's counts or its
`lastActivityAt`. Windows upsert by `folder`, exactly as they upsert agents by `id`.

The counts move on agent changes, so the existing `agent/changed` broadcast is followed by a
`project/changed` for that agent's project. That is one extra small message per agent change and it
is what makes FR-016 true in a window that is looking at a different project.

## Failure codes

Two added to `DaemonAPI.Failure`. The block did not end at `-32010` after all — `shellNotLive` had
taken `-32011` — so these continue after it:

| Code | Name | When |
|---|---|---|
| `-32012` | `noSuchProject` | A folder that is not a project, on archive or unarchive. |
| `-32013` | `projectHasLiveAgents` | Archiving a project with a running or waiting agent. |

`folderGone` (`-32004`) is reused for a missing directory rather than a new code being minted: it
already means exactly that, and `agents/start` already throws it
(`Daemon/DaemonCore+Commands.swift:74`).

## What existing methods do not change

`agents/start` already stats `cwd` and throws `folderGone` before launching a runtime. FR-006 needs
nothing added there — it needs the sidebar to say the folder has gone before the user tries.

## What is deliberately not here

- **No paged archived-agent call.** The window already holds every archived agent (research §4).
- **No `projects/delete`.** Archiving is how the list gets shorter, as it is for agents.
- **No `projects/rename`.** The name is the directory's name.
- **No per-project settings.** A project is a folder, an archived flag and a lead.
- **No method that archives a lead.** `agents/archive` refuses an agent whose role is `.lead`, with
  "The project lead is archived with its project." (FR-046).
- **No method that creates a lead.** `projects/list` makes one when a project has none, and nothing
  else does.
