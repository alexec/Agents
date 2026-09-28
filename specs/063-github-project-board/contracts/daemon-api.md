# Contract: GitHub Project issue board daemon API

The project board is owned by the daemon, like pull requests. All methods are JSON-RPC calls
over the existing daemon connection. `folder` is the project repository folder on the daemon's
host. New methods are allowed only to the existing project-control roles.

## `projectIssues/list`

Return the cached board immediately. Return `null` if the repository is not on GitHub or no
linked Project v2 is known. The Mac then requests a refresh.

```json
→ { "folder": "file:///Users/a/Agents/" }
← {
  "folder": "file:///Users/a/Agents/",
  "repository": { "host": "github.com", "owner": "acme", "name": "agents" },
  "project": { "id": "PVT_…", "title": "Agents", "url": "https://github.com/users/acme/projects/1" },
  "statusOptions": { "ready": "…", "inProgress": "…" },
  "issues": [
    { "nodeID": "I_…", "number": 184, "title": "Add export button",
      "body": "…", "labels": ["enhancement"], "url": "https://github.com/acme/agents/issues/184",
      "itemID": "PVTI_…", "status": "ready", "assignment": null }
  ],
  "fetchedAt": "2026-09-27T18:30:00Z", "problem": null
}
```

## `projectIssues/refresh`

Ask the daemon to refresh the board now. Return the latest successful board, retaining cached
rows and attaching a stale/unreachable problem when a refresh fails. The daemon rate-limits
repeated user refreshes as it does for pull requests.

```json
→ { "folder": "file:///Users/a/Agents/" }
← { "…": "same shape as projectIssues/list" }
```

The daemon publishes `projectIssues/changed` with the board after a successful refresh, an
assignment, or a status-sync retry.

## `projectIssues/assign`

Create a fresh agent and its new issue worktree, save the local issue relationship, and update
the project's status to In Progress. The daemon rejects an issue that is no longer Ready, is
not in the selected project, or already has a live assignment. `requestID` makes a client retry
of the same request idempotent.

```json
→ {
  "folder": "file:///Users/a/Agents/",
  "projectID": "PVT_…", "itemID": "PVTI_…", "issueNodeID": "I_…", "issueNumber": 184,
  "runtimeID": "claude", "prompt": "Implement CSV export…",
  "requestID": "…uuid…"
}
← {
  "agentID": "…uuid…", "branch": "agents/issue-184-add-export-button",
  "worktree": "issue-184-add-export-button", "statusSync": "synced"
}
```

If agent/worktree startup fails, return the ordinary start failure and create no assignment
record. If the agent starts but the GitHub status mutation fails, return the successful
`agentID`, branch, and worktree with `statusSync: "failed"` and a reason; do not start another
agent on retry. The board notification includes the local assignment so the UI can show the
work underway and a status-sync retry.

## `projectIssues/syncStatus`

Retry moving an existing assignment's project item to In Progress. This operation never starts
an agent or creates a worktree.

```json
→ { "folder": "file:///Users/a/Agents/", "projectID": "PVT_…", "itemID": "PVTI_…" }
← { "statusSync": "synced" }
```

## Failure shapes

- No repository / no linked project: `list` returns `null` (the UI hides the section for no
  GitHub repository and explains no linked project for a GitHub repository).
- Missing read permission or unavailable GitHub: preserve cached rows and attach an actionable
  problem.
- Missing project write permission or missing In Progress option: disable assignment and return
  a problem that tells the person what access or project setup is needed.
- Issue no longer Ready, duplicate live assignment, or invalid project-item identity: reject
  before creating an agent or worktree.
- Worktree or runtime start failure: use existing start errors, with no false board association.
