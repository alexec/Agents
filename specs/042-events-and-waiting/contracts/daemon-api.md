# Contract: daemon methods, notification and file syntax

## Methods

| Method | Caller | Request | Reply |
|---|---|---|---|
| `events/wait` | the relay for `wait_for_event` | `EventWaitRequest { token, action, events?, where?, from?, untilMinutes?, limit? }` | `String` (see [event-tools.md](event-tools.md)) |
| `events/cancel` | the relay for `cancel_wait` | `EventTokenRequest { token }` | `String` |
| `events/publish` | the relay for `publish_event` | `EventPublishRequest { token, name, message?, details? }` | `String` |
| `events/list` | Mac and phone | `EventsListRequest { before?, limit, scope?, subjects? }` | `EventsPage` |
| `events/cancelWait` | Mac only | `CancelWaitRequest { agentID }` | `EventsPage.waiting` |
| `events/raise` | tests and scratch only, compiled under `#if DEBUG` and refused unless the store root is a scratch root | `EventDraft` | `Event` |

The token is the app token the agent's MCP session already carries (036's `leaseCaller`). An
unknown token fails with `noSuchAgent`.

`events/list` on a phone goes over the bridge like `leases/snapshot`. `events/cancelWait` is not
in the phone's allowed set (the phone is read-only).

## Notification

`events/changed` carries `EventsChange { event: Event?, waiting: [WaitingAgent] }`. It is sent:

- on each new event
- on each repeat or consequence added to an event (with the updated event)
- on each change to any wait (with `event: nil`)

`AgentsModel` keeps the newest 200 events and inserts or replaces them by `position`.

## Failures

| Code | Name | When |
|---|---|---|
| -32050 | `eventRefused` | Unknown name, bad filter, another project's scope, publish outside `custom.`, publish limit |
| -32051 | `noWait` | `cancel` / `cancelWait` with no open wait |

## Workflow file syntax (additions)

```yaml
on:
  - mac.wake
  - custom.release_ready
  - pull_request.merged:
      number: 41
  - agent.failed
  - pull_request.*
```

- Today's nine names parse exactly as today, and the file is never rewritten (FR-022).
- A dotted name is looked up in the catalogue. If it isn't there, it becomes `unrecognised` and
  stays inert, and the page shows "Waits for “x.y”, which this version does not know about yet".
- A filter key the kind doesn't carry is a file error: `"pull_request.merged" takes number, not
  branch`.
- `agent: triggering` together with a kind that has no `agent` detail is refused at fire time
  with `noTriggeringAgent`. The file is still readable.

## Wire compatibility

| What | New Mac → older phone or Mac |
|---|---|
| `WorkflowTrigger.event` | Sent as `.unrecognised(name, keys)`, so it reads as an unknown trigger and stays inert |
| `Agent.eventWait` | An unknown key is ignored. The agent may read as "Complete" rather than "Blocked" on the old device. |
| `WorkflowOutcome.causingEvent` | An unknown key is ignored |
| `events/*` | Never called by an old device |
