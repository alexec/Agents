# Contract: the daemon's Dashboard methods

## For agents (relayed by `agentsd mcp`, in `ConnectionRole.agentMethods`)

| Method | Params | Result |
|---|---|---|
| `dashboard/setTile` | `{token, arguments: JSON}` | `{note}` |
| `dashboard/removeTile` | `{token, id}` | `{note}` |
| `dashboard/read` | `{token}` | `{note}` |

## For people (window, Remote, web page; in `WebSignatures`)

| Method | Params | Result |
|---|---|---|
| `dashboard/get` | `{folder}` | `DashboardSnapshot` |
| `dashboard/summaries` | `{}` | `[DashboardSummary]` |
| `dashboard/hide` | `{folder, id}` | `Empty` |
| `dashboard/show` | `{folder, id}` | `Empty` |
| `dashboard/remove` | `{folder, id}` | `Empty` |
| `dashboard/update` | `{folder}` | `DashboardUpdate` |

**Update now (#146).** `dashboard/update` runs the project's workflow labelled `dashboard` (not
archived, the first by file name) as `workflows/run` would, off or on, or, with none, starts a
one-off agent labelled `dashboard` with the app's own prompt (`DashboardUpdate.oneOffPrompt`).
It is refused, in a sentence, while one is running, within 5 minutes of the last start, or while
the workflow waits for approval or is past a ceiling. `DashboardSnapshot.update` carries where it
stands (`workflowID`, `name`, `isRunning`, `agentID`, `lastStartedAt`, `lastFailed`, `blocked`);
an agent labelled `dashboard` changing state sends `dashboard/changed`, so the page follows it.

Refusals use `DaemonAPI.Failure.dashboardRefused` (-32060) with a sentence.

## Notification

`dashboard/changed` `{folder, summary: DashboardSummary}`: at most once a second per project,
after any set, remove, hide, show or outside change. A client showing that Dashboard asks
`dashboard/get` again; every client updates the row from `summary`.
