# Data model: MCP integrations, a proof of concept

Phase 1 for [plan.md](plan.md). The reasons for each choice are in [research.md](research.md).

## MCPEventTrigger (AgentsKitCore, value type)

One `on:` entry naming a server's event. It is held in `WorkflowTrigger.serverEvent`.

| Field | Type | Rule |
|---|---|---|
| `event` | String | The name as written, `noun.verbed`: `[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*`. Not in the app's catalogue, and the noun not one of the app's subjects or `custom`. |
| `server` | String? | From the reserved `server:` key. `nil` means "whichever server offers it". If present, it must match `[A-Za-z0-9_-]+`. |
| `arguments` | `[String: JSONValue]` | Every other key under the trigger. Empty when there are none. At most 2 KB as JSON (the same as pin arguments). |
| `subscriptionKey` | String, derived | `sha256(resolvedServer + "\n" + event + "\n" + canonicalJSON(arguments))`, the first 16 hex characters. It is worked out once the server is resolved. |

- `name` is `event`.
- `matches(event)` is true when the event's name equals `name` and its `subscription` detail
  equals the trigger's resolved `subscriptionKey`.
- **Parse errors are file errors**: a bad `server:` value, arguments over 2 KB, or a
  `noun.verbed` name whose noun is reserved. Today the last one is a file error for a name
  the app doesn't know.
- **Resolution**, done by the daemon per project and host, needs the servers, so its results
  show on the trigger's status, not as file errors:
  - No server offers it: `serverNotFound`.
  - Two or more offer it and there is no `server:`: `ambiguous`, naming them.
  - The named server doesn't offer it: `eventNotOffered`.
  - The arguments don't fit the schema: `badArguments`.

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
| `name` | String, such as `checks.failed` |
| `server` | String?, the server it resolved to |
| `state` | `pending`, `active`, `retrying`, `stopped` or `notThisHost` |
| `lastPolledAt`, `lastEventAt`, `missedSince` | Date? |
| `failure` | `{ code, message, since }?` |

The failure codes are `serverNotFound`, `ambiguous`, `badEventName`, `waitingForApproval`, `secretMissing`, `needsSignIn`,
`unreachable`, `noEvents`, `eventNotOffered`, `noPollMode`, `badArguments`, `refused` and
`serverError`. `message` is a whole sentence in the app's voice, so clients don't each word it.

## The raised event (existing `EventDraft`)

| Field | Value |
|---|---|
| `name` | the server's event name, as it is (`checks.failed`) |
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

`EventCatalogue` gains `reservedNouns` (its subjects plus `custom`) and an `isEventName`
check (`noun.verbed`). A raised server event is accepted by `EventPattern` when its name is not
the app's and its noun is not reserved. A **wait** (`wait_for_event`) on `checks.failed` (or
`checks.*`) therefore works with no extra work while some workflow subscribes, and the Events
page lists these events like any other, with the server from `details.server`.
