# Data Model: An Agent Can Move into a Worktree Mid-Work

## MoveTarget (new, AgentsKitCore/Model/AgentMove.swift)

Where the agent will go.

| Case | Carries | Made from |
|------|---------|-----------|
| `newWorktree(name: String?)` | The name the agent gave, or none | `enter_worktree` with `name` or neither; the capsule's New worktree |
| `existing(URL)` | A worktree root of the project's repository | `enter_worktree` with `path`; a listed worktree in the capsule |
| `projectFolder` | — | `exit_worktree`; the capsule's Project folder |

A `path` equal to the project repository's top is read as `projectFolder`.

## PendingMove (new)

| Field | Type | Notes |
|-------|------|-------|
| `target` | `MoveTarget` | |
| `removeLeft` | `Bool` | `exit_worktree action: remove`. Only with `projectFolder`. |
| `discardChanges` | `Bool` | Only with `removeLeft`. Lets removal go ahead over uncommitted or unmerged work (030 FR-020's confirmation). |
| `askedBy` | `MoveAsker` | `.agent`, or `.person`. Decides whether a turn starts after (FR-013). |
| `askedAt` | `Date` | |

**Validation**, at ask time, in the daemon, answered in words:
- The project folder is in a git repository.
- `existing` is a worktree of that repository, and it's there.
- `removeLeft` needs the agent to be in a worktree the app made, with no other agent that is not
  archived working in it. Uncommitted or unmerged work needs `discardChanges`.
- `exit_worktree` from the project folder is a no-op, with a message, and nothing is stored.
- `enter_worktree` for the folder the agent is already in is a no-op too.

At apply time the same checks run again. Anything that changed since is handled as follows:
- A target that can no longer be made: the agent stays where it is, and the chat says why.
- A removal that would now lose work: the move happens, the removal is skipped, and the chat says
  why.

## Agent (changed)

| Field | Change |
|-------|--------|
| `cwd` | Rewritten by a move: the new worktree's working folder (030 `workingFolder(in:prefix:)`), or `worktree.project` on exit. |
| `worktree` | Set to the new or chosen `AgentWorktree`, with `project` = the agent's `projectFolder`, unchanged. Nil on exit. |
| `pendingMove` | **New**, `PendingMove?`. Encoded if present, decoded with `decodeIfPresent`. Older daemons and phones ignore it. Cleared when applied, cancelled, archived or deleted. A later request replaces it (FR-004). |

`projectFolder` (030) doesn't change across a move, so filing, costs and the 028 helper limit stay
put.

## In-memory (DaemonCore)

- `moveNotes: [UUID: String]`: the one-shot preface for the agent's next prompt: "You now work
  in <path> (worktree <name> on <branch>). Uncommitted changes in <old> stayed there." It's
  consumed in `beginTurn` next to `artifactEdits`. If it's lost on a daemon restart, the runtime
  still starts in the new folder and the chat line is in the transcript.

## Chat lines (existing `.runtimeNote`)

- On ask: "Will move to a new worktree like <name> when this turn ends." For the person's move
  mid-turn: "… when this turn ends (asked by you)."
- On apply: "Moved from <old> to worktree <name> on <branch>, from <base>. <n> uncommitted
  changes stayed in <old>." Or "Moved back to the project folder. Removed the worktree <name>
  [and its branch]."
- On session: 025's existing "Picked back up" note, or "… no longer has this conversation.
  Carrying on in a new one …". With Handover, the second one adds "and was given the conversation
  so far".
- On failure: "Could not move: <reason>. Still in <old>."

## Wire (DaemonAPI)

See [contracts/move.md](contracts/move.md): `MoveSelfRequest`, `MoveRequest` and `MoveAnswer`.
