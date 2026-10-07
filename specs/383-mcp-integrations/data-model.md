# Data model: MCP integrations, a proof of concept

Phase 1 for [plan.md](plan.md). The reasons for each choice are in [research.md](research.md).

## MCPEventTrigger (AgentsKitCore, value type)

One `on:` entry naming an MCP event. It is held in `WorkflowTrigger.mcpEvent`.

| Field | Type | Rule |
|---|---|---|
| `server` | String | Non-empty. No dots. One of `[A-Za-z0-9_-]`. |
| `event` | String | Non-empty. The rest of the name after `mcp.<server>.`. |
| `arguments` | `[String: JSONValue]` | The keys under the trigger. Empty when there are none. At most 2 KB as JSON (the same as pin arguments). |
| `subscriptionKey` | String, derived | `sha256(server + "\n" + event + "\n" + canonicalJSON(arguments))`, the first 16 hex characters. |

- `name` is `mcp.<server>.<event>`.
- `matches(event)` is true when the event's name equals `name` and its `subscription` detail
  equals `subscriptionKey`.
- **Parse errors are file errors**: a server name with a dot or a bad character, an empty
  event, or arguments over 2 KB.
- **Not file errors when the file is read**: an unknown server, an unknown event, or arguments
  that don't fit the schema. These need the server, so they show on the trigger's status
  (below).

## MCPSubscription (daemon, one per host, server, event and arguments)

The workflows' triggers, put together. Many workflows can share one subscription.

| Field | Type | Notes |
|---|---|---|
| `key` | String | `subscriptionKey` |
| `project` | folder URL | Subscriptions are per project, because servers resolve per project. |
| `server`, `event`, `arguments` | | As on the trigger. |
| `workflows` | `[workflowID]` | Built again on every workflow rescan. |

A subscription exists only while at least one of its workflows is on, not archived, has no
file problem, and runs on this host (`hosts:`).

## MCPSubscriptionRecord (durable, `<root>/mcp-events.json`)

The record is a map from `"<project path>|<key>"` to a record. The daemon is the only writer.
Writes are atomic (write to a temp file, then rename), and synced at R4 step 3.

| Field | Type | Notes |
|---|---|---|
| `cursor` | String? | The last cursor the server gave. `nil` before the first poll. |
| `previousCursor` | String? | The cursor before the last poll, used to fetch again what was still being delivered (R4). |
| `seen` | `[{id, at}]` | Ids already raised (or recorded at start-from-now). Kept for 7 days, at most 2,000. |
| `delivering` | `[String]` | Ids written ahead of `raise`. Empty when the record is at rest. |
| `lastPolledAt` | Date? | |
| `lastEventAt` | Date? | |
| `missedSince` | Date? | Set by `truncated: true`. Cleared by **Clear** on the page, or after 7 days. |
| `failure` | `MCPTriggerFailure?` | The current error, with `since`. |
| `nextPollAt` | Date | Not shown. Used to resume the pace after a restart. |

When no subscription has a key for 24 hours, its record is deleted (a changed filter, a deleted
workflow).

## MCPTriggerState (states of a subscription)

```
            (first list)               (poll ok)
 pending ───────────────▶ subscribing ───────────▶ active ◀───┐
    │                          │                    │  │      │ (poll ok)
    │                          │ bad args /         │  └──────┘
    │                          │ not offered /      │ transport error
    │                          ▼ no poll mode       ▼
    │                       stopped ◀──────── retrying (10s → 5 min backoff)
    │                          ▲   NotFound / Forbidden
    └── server not found ──────┘
```

- **`stopped`** waits for a change: the workflow's file, the server's event list
  (`list_changed` or the 10-minute relist), sign-ins, or `secrets.env`.
- **`retrying`** keeps the last cursor and goes back to `active` on the first good poll.

## MCPTriggerStatus (wire; on `WorkflowSummary.mcpTriggers`)

There is one per MCP trigger in the workflow, in file order. The full shape is in
[contracts/wire-status.md](contracts/wire-status.md).

| Field | Type |
|---|---|
| `name` | String, such as `mcp.ci.checks.failed` |
| `state` | `pending`, `active`, `retrying`, `stopped` or `notThisHost` |
| `lastPolledAt`, `lastEventAt`, `missedSince` | Date? |
| `failure` | `{ code, message, since }?` |

The failure codes are `serverNotFound`, `waitingForApproval`, `secretMissing`, `needsSignIn`,
`unreachable`, `noEvents`, `eventNotOffered`, `noPollMode`, `badArguments`, `refused` and
`serverError`. `message` is a whole sentence in the app's voice, so clients don't each word it.

## The raised event (existing `EventDraft`)

| Field | Value |
|---|---|
| `name` | `mcp.<server>.<event>` |
| `scope` | `.project(folder)` |
| `sentence` | `<server> reported <event>` |
| `details.server` | `<server>` |
| `details.event` | `<event>` |
| `details.subscription` | the subscription key |
| `details.mcp_event_id` | the server's `eventId` |
| `details.time` | the server's `timestamp` (ISO 8601) |
| `details.payload` | the event's `data`, compact JSON, at most 256 KB |
| `details.payload_cut` | `"true"` only when it was cut |
| `publisher` | none (it is not an agent) |

`EventSubject` gains `mcp`, and `EventCatalogue` treats `mcp.` names as open, as it does
`custom.`. A **wait** (`wait_for_event`) on `mcp.ci.*` therefore works with no extra work, and
the Events page lists these events like any other.
