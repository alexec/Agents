# Contract: what the app asks the daemon

**Feature**: [spec.md](../spec.md) | **Plan**: [plan.md](../plan.md)

Line-delimited JSON-RPC 2.0 over a Unix socket at
`~/Library/Application Support/Agents/daemon.sock`, using the same connection code as the ACP side.

The app holds no state. It connects, lists, subscribes, and renders what arrives. Every user action
is one of these calls.

## Connecting

1. Try the socket. If it answers, done.
2. If not, spawn `Contents/Helpers/agentsd` in its own session and retry with backoff for a few
   seconds.
3. If it still does not answer, show what happened. This is a bug, not a state the user manages.

Several connections at once are normal and all of them get the same notifications (FR-016).

## Calls

| Method | Params | Returns |
|---|---|---|
| `runtimes/list` | — | Each runtime with its availability: found and where, missing and where we looked, or found but not signed in with the command that fixes it |
| `agents/list` | `includeArchived` | Every agent with its state, title, folder, runtime and last activity. No transcripts |
| `agents/start` | `runtimeId`, `cwd`, `prompt`, `startOptions` | The new agent's id. The daemon creates the session, applies the options, then sends the prompt |
| `agents/options` | `runtimeId`, `cwd` | The `configOptions` for a session, so the start form can be filled before the user commits. Creates a session the start call then reuses |
| `agents/prompt` | `agentId`, `text` | Accepted. Starts a turn, picking the agent up first if it is stopped, finished or archived |
| `agents/stop` | `agentId` | Accepted. Cancel, close, terminate |
| `agents/archive` | `agentId` | Accepted. Stops it first if it is alive |
| `agents/unarchive` | `agentId` | Accepted |
| `agents/transcript` | `agentId`, `before`/`limit` | A page of entries, newest last. Never the whole thing |
| `agents/setOption` | `agentId`, `optionId`, `value` | The refreshed option list |
| `permissions/answer` | `permissionId`, `optionId` | Accepted. Replies to the waiting agent |
| `permissions/pending` | — | Every question waiting on the user, so a window that has just opened shows them immediately |

## Notifications

Sent to every connected app.

| Notification | When |
|---|---|
| `agent/changed` | An agent's state, title, options or last activity changed |
| `agent/entry` | A transcript entry was appended. The live stream the window renders |
| `agent/permission` | An agent is asking, or has stopped asking |
| `runtime/changed` | A runtime appeared, vanished or needs signing in |

## Errors

Plain JSON-RPC errors carrying something a person can read. The ones worth naming:

| Case | What the app shows |
|---|---|
| The runtime could not be found | Which runtime, and where we looked |
| The runtime would not start a session | What it said, plus its own auth methods and fix command when it gave them |
| The runtime could not give the session back | That it is gone, the agent's history is intact, and an offer to carry on in the same folder as the same agent (FR-012d) |
| The folder is gone | Which folder, and that the agent cannot run until it is back |

## The daemon's own life

- One daemon: an exclusive `flock` on `daemon.lock`. A daemon that loses the lock exits silently.
- It exits when it holds no agents and no app is connected, after a short grace period (FR-019).
  Running, waiting on a permission, and finished-with-a-live-process all count as holding (FR-019a).
- On start it reads every agent record, and any agent whose process is gone becomes `stopped` with
  `daemonGone` (FR-019b). This is the first thing it does, before it accepts a connection, so the app
  never sees a state it knows to be a lie.
