# Feature counts (#2165)

Count which features people use, on their own machines, and show the counts in Reports.

## What is counted

- **One count per use:** the day (in the host's zone), the method and the client. Never the
  arguments, a title, a path or a prompt.
- **The methods:** every method the host serves (`d.handlers`) and every app tool, by its
  method name (`appToolMethod`, such as `sessions/start`). A method the host does not serve
  is not counted, so a caller cannot add names.
- **Where:** in the host's dispatch (`Go/internal/agentsd/rpc.go`), after a call is
  answered without an error, and after each app tool call (`apptools.go`).
- **The clients:**

  | Client | The connection |
  |---|---|
  | `mac` | The Mac's window: a control-plane channel with no device, the local socket, Agents Host's window |
  | `remote` | A device this Mac paired as an iPhone or an iPad (`devices.json`) |
  | `web` | Any other device (a browser), or the page this host carries (`pageChannel`) |
  | `agent` | An agent's helper on the socket, or an app tool call |
  | `workflow` | An app tool call from an agent that a workflow started |

  A stranger's and a pairing phone's calls are not counted.

## The file

`<root>/features-history.json`, day → method → client → uses:

```json
{"days": {"2026-10-30": {"sessions/start": {"mac": 3, "agent": 12}}}}
```

- 90 days are kept; the oldest goes when a new day starts.
- The counts are kept in memory and written at most once a minute when they changed, and
  once more when the host stops.
- Bound: 90 days × the methods served × 5 clients.

## The method

`reports/features` (host, `features/1`, tagged `web`): no params. It answers each feature
with `week` (the last 7 days, today included), `quarter` (the last 90 days), `clients` and
`lastUsed`, the least used first. A feature with no use is in the answer too. `since` is the
first day counted.

## The view

**Reports ▸ Features**, Mac + web tier (#2796):

- **Mac:** Cost ▸ Reports ▸ Page ▸ Features (`Shared/UI/ReportsPane.swift`). It asks this
  Mac's host and every connected server, and adds them up (`FeatureUsage.merged`).
- **Web:** Reports ▸ Features (`Web/src/views/Reports.tsx`). It asks every machine that
  answers, and adds them up (`mergeFeatures`).
- **Remote:** none (tier mac+web).

Each row: the method, "Not used" when it has no use in 90 days, then "7 this week · 30 in 90
days · mac, web". The note says since when it counts, and that the counts stay on the machines.

## Later

- Client-only actions (a pane opened, a setting changed in the window only).
- A setting to turn counting off.
- The team's counts on the control plane's Reports (#1811).
