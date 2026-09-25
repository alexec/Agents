# Data Model: An Agent Can Work in a Worktree of Its Own

One new optional field on the agent record, one new choice type on start requests, and one
listing type. No new stored files: the app's worktrees are found in git, not kept in a list
(research R6).

## AgentWorktree (new, `AgentsKitCore/Model/AgentWorktree.swift`)

The worktree an agent was started in. It's stored on the agent, so it survives restarts, resumes
and the worktree itself being deleted.

| Field | Type | Meaning |
|---|---|---|
| `name` | `String` | Folder name, e.g. `fix-login-redirect-safari`. What the row shows. |
| `root` | `URL` | The worktree's top folder. The agent's `cwd` is this, or the matching subfolder of it (edge case: project is a subfolder). |
| `branch` | `String?` | `agents/<name>` for one the app made; whatever it had for an existing one; nil if detached. |
| `project` | `URL` | The project folder it was started from. Filing uses this (FR-014). |
| `base` | `String?` | Branch name, or commit when detached, that a new worktree was made from. Nil for an existing worktree chosen by the person. Used for "merged" (R7). |
| `madeByApp` | `Bool` | True when this start made it. |

Validation:
- `cwd` is `root` or a folder inside it.
- `project` is standardized with `Project.standardize`.
- When `madeByApp` is true, `root` is under `<toplevel>/.agents/worktrees/` and `branch` starts with `agents/`.

## Agent (changed, `AgentsKitCore/Model/Agent.swift`)

| Change | Detail |
|---|---|
| `+ worktree: AgentWorktree?` | `decodeIfPresent`/`encodeIfPresent`, same as `startedByAgent`. Old records and old phones keep working. |
| `+ projectFolder: URL` (computed) | `Project.standardize(worktree?.project ?? cwd)`. Used everywhere an agent is filed under a project (research R5). |

Nothing about agent state changes. Archiving leaves `worktree` in place (FR-018).

## WorktreeChoice (new, `AgentsKitCore/Model/AgentWorktree.swift`)

```text
enum WorktreeChoice: Codable, Hashable, Sendable
  case new                // make one, named from the prompt
  case existing(URL)      // a worktree of the same repository
```

Encoded as `{"new": {}}` or `{"existing": {"_0": "file:///…"}}`, which is Swift's default for
enums with associated values, as used by `WorkflowTrigger`. Nil on a request means the project
folder.

Carried by:
- `DaemonAPI.StartRequest.worktree: WorktreeChoice?`: `decodeIfPresent`, and older senders
  don't send it.
- `DaemonAPI.StartHelperRequest.worktree: String?`: from `start_agent`, as the agent wrote it, either `"new"` or a worktree's name. The daemon resolves it into a `WorktreeChoice`, because only the daemon can see what exists. *(Changed in implementation from `WorktreeChoice?`.)*
- `AppModel.draftWorktree: WorktreeChoice?`: the start bar's choice. Reset to nil after each start. *(Changed in implementation: it isn't in `StartDraft`, which is the form kept across launches, because a worktree is decided per agent.)*

## WorktreeSummary (new, wire only, `DaemonAPI.swift`)

What the chooser and the project page list. Built on demand from `git worktree list --porcelain`.

| Field | Type | Meaning |
|---|---|---|
| `name` | `String` | Last path component. |
| `root` | `URL` | Its folder. |
| `branch` | `String?` | Nil when detached. |
| `isProjectFolder` | `Bool` | The project folder itself (it's listed so the chooser can skip it). |
| `exists` | `Bool` | False for git's `prunable` entries, or when the folder is gone (FR-003). |
| `madeByApp` | `Bool` | R6: under `.agents/worktrees/` with an `agents/` branch. |
| `agents` | `[UUID]` | Agents that aren't archived and whose `cwd` is inside `root`. |

And its envelope:

| Field | Type | Meaning |
|---|---|---|
| `isRepository` | `Bool` | False hides the Worktree choice (FR-001). |
| `canMakeNew` | `Bool` | False when the repository has no commit yet. |
| `whyNot` | `String?` | The reason shown on a disabled New worktree. |
| `worktrees` | `[WorktreeSummary]` | |

## RemovalCheck (new, wire only)

The answer to "what would removing this lose?", given before anything is removed.

| Field | Type | Meaning |
|---|---|---|
| `blockedBy` | `[UUID]` | Agents that aren't archived and are working in it. Non-empty means removal is refused (FR-020). |
| `uncommitted` | `Int` | Lines of `status --porcelain`. |
| `unmerged` | `Bool` | Branch not an ancestor of the base (R7). |

## DaemonCore state (in memory only)

| Field | Meaning |
|---|---|
| `reservedWorktreeNames: Set<String>` | Names picked by starts that haven't finished `worktree add` yet, keyed as `<toplevel>/<name>` (R3). |

## New failure codes (`DaemonAPI.Failure`)

| Code | When |
|---|---|
| `worktreeFailed` | `git worktree add` or its preparation failed. The message is git's. No agent is made (FR-013). |
| `worktreeMissing` | Resuming an agent whose worktree folder is gone (R8). |
| `notAWorktree` | A chosen existing worktree isn't one of this repository's (US4-3). |
| `worktreeInUse` | Removing a worktree that an agent (not archived) is working in. |
