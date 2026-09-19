# Contract: Daemon API additions

JSON-RPC over the daemon's unix socket, following the shapes already in `DaemonAPI`. Everything here goes in `AgentsKitCore/Daemon/DaemonAPI.swift`, routed in `DaemonCore+Dispatch.swift`.

## Methods

| Method | Request | Response | Notes |
|---|---|---|---|
| `workflows/list` | `{ folder: URL?, }` | `[WorkflowSummary]` | `folder` nil lists every project's |
| `workflows/run` | `{ folder, workflowID }` | `WorkflowSummary` | Run now (FR-012). Depth 0. Subject to the in-flight and paused rules, and says so |
| `workflows/pause` | `{ folder, workflowID, paused: Bool }` | `WorkflowSummary` | Writes only to `workflows.json` |
| `workflows/pauseProject` | `{ folder, paused: Bool }` | `[WorkflowSummary]` | FR-024 |
| `workflows/confirm` | `{ confirmationID: UUID, allow: Bool }` | `{}` | Answers a pending write confirmation |
| `workflows/pendingConfirmations` | `{}` | `[WorkflowConfirmation]` | For a window that has just connected, mirroring `permissions/pending` |

## Notifications

| Notification | Payload | Sent when |
|---|---|---|
| `workflow/changed` | `WorkflowSummary` | A file appears, changes or is removed; a fire runs or is refused; pause changes; a run starts or ends |
| `workflow/removed` | `{ folder, workflowID }` | The file is gone |
| `workflow/confirmation` | `{ confirmation: WorkflowConfirmation? }` | A write is waiting on the user, or has been answered (nil) |

`workflow/changed` carries the whole resolved summary rather than a delta, for the reason `ProjectSummary` does: two windows cannot then disagree, and a window that missed a notification is corrected by the next one.

## `WorkflowConfirmation`

What a window shows when an agent wants to write a workflow. FR-036 requires this to be judgeable without opening a file, so it carries the rendered summary, not a diff.

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `agentID` | `UUID` | Who asked |
| `folder` | `URL` | |
| `workflowID` | `String` | |
| `action` | `create` \| `update` \| `remove` | |
| `summary` | `String` | *"Runs every weekday at 9:00am, in a new agent."* Same renderer as the project page row |
| `prompt` | `String` | The body, so the reader can see what the agent would be told |
| `askedAt` | `Date` | |

There is deliberately no *always allow*. Each write is confirmed on its own: a workflow able to approve the writing of further workflows is not gated at all.

## Failure codes

Continuing from `-32013`, which is the highest currently used.

```
public static let noSuchWorkflow    = -32014
public static let workflowUnreadable = -32015
public static let notInWorkflowFolder = -32016
public static let confirmationTimedOut = -32017
```

> **Pre-existing collision, not fixed here.** `DaemonAPI.Failure` already defines both `shellWillNotStart` and `notConfirmed` as `-32010`. Nothing in this feature depends on either, and the new codes avoid the range, but it is worth a separate fix: a client cannot tell those two apart today.

## Behaviour the methods must hold to

- **Persist, then broadcast.** Every one of these writes `workflows.json` before sending a notification, the rule `record(_:for:)` already follows, so a daemon killed mid-call leaves something true behind.
- **`workflows/run` is not a bypass.** It sets depth 0 and ignores the schedule, and it still obeys the in-flight and paused rules — returning a summary whose `lastOutcome` is the refusal. Someone is watching when they tap it, so being told why is more important here than anywhere else.
- **`workflows/pause` never touches the repository.** FR-024 is a contract, not an implementation note.
- **Unknown-shaped requests are refused with a sentence**, in the voice the existing errors use — `"There is no workflow called morning-check in this project."` — because an agent may be reading it.
