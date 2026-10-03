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

Refusals use `DaemonAPI.Failure.dashboardRefused` (-32060) with a sentence.

## Notification

`dashboard/changed` `{folder, summary: DashboardSummary}`: at most once a second per project,
after any set, remove, hide, show or outside change. A client showing that Dashboard asks
`dashboard/get` again; every client updates the row from `summary`.
