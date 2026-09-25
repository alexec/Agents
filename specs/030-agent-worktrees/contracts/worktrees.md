# Contract: Worktrees

Shapes for the daemon socket (JSON-RPC over `daemon.sock`), the `start_agent` tool, and the start
bar. Types are in [data-model.md](../data-model.md).

## Daemon methods

### `agents/start` (changed)

A `worktree` field is added to the existing `StartRequest`:

```json
{ "runtimeID": "claude", "cwd": "file:///Users/a/Agents/", "prompt": "Fix the login redirect on Safari",
  "worktree": { "new": {} } }
```

- **Leaving `worktree` out**: exactly today's behaviour.
- **`new`**: the daemon does the following in order:
  1. Resolves the repository from `cwd`.
  2. Names the worktree (R3).
  3. Makes sure of the exclude line (R4).
  4. Runs `git worktree add`.
  5. Launches the runtime with the process and session `cwd` both = `<root>/<prefix>`.
  6. Saves the agent with `worktree` set.
  7. Records the first chat line: `Working in worktree <name> on <branch>, from <base>.`
- **`existing`**: the daemon checks that the URL is a worktree of the same repository. It
  refuses with `notAWorktree` if not, and with `worktreeMissing` if the folder is gone. Then it
  starts there, with `madeByApp` taken from R6 and `base` nil.
- **On any git failure**: `worktreeFailed`, with git's message. No agent is saved and no runtime
  is left running. If the worktree was made but the runtime failed to start, the worktree is left
  in place and the message names it (removing it could lose a hook's output, and it's listed for
  cleanup).
- **Response**: unchanged, the `Agent`, now with `worktree`.

### `agents/options` (unchanged shape)

For `existing`, the app sends the worktree folder as `cwd` so the draft can be reused. For `new`,
it sends the project folder as today, and the start discards that draft (R2).

### `worktrees/list` (new)

```json
→ { "folder": "file:///Users/a/Agents/" }
← { "isRepository": true, "canMakeNew": true, "whyNot": null,
    "worktrees": [ { "name": "fix-login-redirect-safari",
                     "root": "file:///Users/a/Agents/.agents/worktrees/fix-login-redirect-safari/",
                     "branch": "agents/fix-login-redirect-safari", "isProjectFolder": false,
                     "exists": true, "madeByApp": true, "agents": ["…uuid…"] } ] }
```

- For a folder that isn't in a repository: `isRepository: false`, the list is empty, and there's
  no error.
- It's called when the start bar's folder changes, when the chooser opens, and when the project
  page appears. It's never polled (see memory: daemon socket polling exhausts descriptors).

### `worktrees/check` (new)

```json
→ { "project": "file:///…/Agents/", "root": "file:///…/.agents/worktrees/x/" }
← { "blockedBy": [], "uncommitted": 3, "unmerged": true }
```

The caller shows this and asks for confirmation before `worktrees/remove`.

### `worktrees/remove` (new)

```json
→ { "project": "file:///…/Agents/", "root": "file:///…/.agents/worktrees/x/", "confirmed": true }
← { "removedBranch": true }
```

- **An agent (not archived) is working in it**: refused with `worktreeInUse`, naming the agents.
- **Not made by the app** (R6): refused with `notAWorktree` (FR-021).
- **`confirmed: false` with anything to lose**: refused with a message saying what would be lost.
  The daemon doesn't rely on the client having asked.
- **Otherwise**: it removes the worktree, and removes the branch by R7. It then sends
  `projectChanged`, so open pages refresh.

## `start_agent` tool (changed, 028)

One new optional property in its input schema:

```json
"worktree": {
  "type": "string",
  "description": "Where the new agent works. Leave out to work in the project folder. \"new\" makes a fresh git worktree named from the prompt. Or give the name of an existing worktree of this repository, as list_my_agents or `git worktree list` shows it."
}
```

The tool's result text adds `It is working in worktree <name> on <branch>.` when a worktree was
used. Failures are returned as tool errors carrying the daemon's message.

## Start bar (Mac)

- **Where**: a `SelectCapsule` named **Worktree**, placed right after the folder button and before
  the spacer. It appears only when `worktrees/list` says `isRepository`.
- **Title**: `Project folder`, `New worktree`, or the chosen worktree's name.
- **Choices, in order**:
  1. **Project folder**, with the description "Work alongside anything else here".
  2. **New worktree**, with the description "A new branch from the last commit here", or `whyNot`,
     disabled, when it can't be made.
  3. A divider, then each existing worktree that isn't the project folder:
     - The title is its name.
     - The description is `branch · N agents working` (or `detached`).
     - One that is missing is disabled and says "Missing".
- **After a start**: back to Project folder.
- **On a project page**: shown even though the folder button is fixed (FR-005).

## Agent row and page (Mac and phone)

- **Badge**: a small `arrow.triangle.branch` symbol with the worktree name, after the title. The
  tooltip is `branch — full path`.
- **Missing worktree**: the badge shows it as gone, and the row's resume error is the
  `worktreeMissing` message.

## Project page (Mac)

- **Where**: a **Worktrees** section under the agent groups, listing only `madeByApp` worktrees.
  Each row shows its name, branch, its agents, and a **Remove…** button.
- **Remove…**:
  1. Calls `worktrees/check`.
  2. If blocked, it shows the agents and offers no confirm button.
  3. If there's something to lose, it confirms, naming what: "3 uncommitted changes and commits
     not in main".
  4. Otherwise it removes straight away.
- **When there are none**: the section is hidden.
