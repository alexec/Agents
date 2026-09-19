# Contract: Daemon API additions

JSON-RPC over the daemon's unix socket, following the shapes already in `DaemonAPI`. Everything here goes in `AgentsKitCore/Daemon/DaemonAPI.swift`, routed in `DaemonCore+Dispatch.swift`.

## Methods

| Method | Request | Response | Notes |
|---|---|---|---|
| `workflows/list` | `{ folder: URL?, }` | `[WorkflowSummary]` | `folder` nil lists every project's |
| `workflows/run` | `{ folder, workflowID }` | `WorkflowSummary` | Run now (FR-012). Depth 0. Subject to the in-flight, ceiling and archive rules, and says so |
| `workflows/archive` | `{ folder, workflowID, archived: Bool }` | `WorkflowSummary` | FR-031a. Writes only to `workflows.json`; clears `lastOutcome`, which belonged to the life it had before |

## Notifications

| Notification | Payload | Sent when |
|---|---|---|
| `workflow/changed` | `WorkflowSummary` | A file appears, changes or is removed; a fire runs or is refused; it is archived or restored; a run starts or ends |
| `workflow/removed` | `{ folder, workflowID }` | The file is gone |

`workflow/changed` carries the whole resolved summary rather than a delta, for the reason `ProjectSummary` does: two windows cannot then disagree, and a window that missed a notification is corrected by the next one.

## No write confirmation

There was one — `workflows/confirm`, `workflows/pendingConfirmations`, a `workflow/confirmation` notification and a `WorkflowConfirmation` type — and all of it is gone. A write now happens and is reported. See FR-035 in the spec for why, and `workflows/archive` for what took its place.

`manage_workflows` is auto-allowed alongside the app's other two tools, so a runtime that asks before every call cannot stall it either.

## Failure codes

Continuing from `-32013`, which is the highest currently used.

```
public static let noSuchWorkflow    = -32014
public static let workflowUnreadable = -32015
public static let notInWorkflowFolder = -32016
public static let workflowLimitReached = -32017
```

`-32017` was `confirmationTimedOut`, which is gone — nothing times out, because nothing waits — and the number is now `workflowLimitReached`.

> **Pre-existing collision, not fixed here.** `DaemonAPI.Failure` already defines both `shellWillNotStart` and `notConfirmed` as `-32010`. Nothing in this feature depends on either, and the new codes avoid the range, but it is worth a separate fix: a client cannot tell those two apart today.

## Behaviour the methods must hold to

- **Persist, then broadcast.** Every one of these writes `workflows.json` before sending a notification, the rule `record(_:for:)` already follows, so a daemon killed mid-call leaves something true behind.
- **`workflows/run` is not a bypass.** It sets depth 0 and ignores the schedule, and it still obeys every other rule — the run in flight, the ceilings, the archive — returning a summary whose `lastOutcome` is the refusal. Someone is watching when they tap it, so being told why is more important here than anywhere else.
- **`workflows/archive` never touches the repository.** FR-024 is a contract, not an implementation note: archiving is the app forgetting to act on a file, not the app deleting somebody's file.
- **There is no `workflows/pause`.** There was, and it is gone with the feature: pausing and archiving both meant "do not run this", both undone in one call, and two ways to say one thing is one too many. A client that calls it gets method-not-found.
- **The ceilings are resolved by the daemon, not the window.** `WorkflowSummary.overLimit` is computed by taking each project's non-archived workflows in name order, capping each project at three, then capping the lot at ten in project-path order. Two windows cannot count differently, and a phone gets the same answer as a Mac.
- **Unknown-shaped requests are refused with a sentence**, in the voice the existing errors use — `"There is no workflow called morning-check in this project."` — because an agent may be reading it.
