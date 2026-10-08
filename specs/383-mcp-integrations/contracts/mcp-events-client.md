# Contract: the daemon as an MCP events client (poll mode)

This is the subset of the
[draft](https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
that the daemon speaks. Anything else from the draft is not sent, and if received it is
ignored and logged once per connection.

## Initialize

- The daemon offers `protocolVersion: "2026-07-28"`, and accepts `"2025-06-18"` back.
- The server has events if its `initialize` result's `capabilities` has an `events` object.
  `events.listChanged: true` means the server may send `notifications/events/list_changed`.

## `events/list`

Request: `{}`. Paging with `cursor` / `nextCursor` is followed if present.

Response used:

```json
{ "events": [ {
    "name": "checks.failed",
    "description": "A pull request's checks finished with a failure.",
    "delivery": ["poll"],
    "inputSchema":   { "type": "object", "properties": { "repo": {"type":"string"}, "branch": {"type":"string"} }, "required": ["repo"] },
    "payloadSchema": { "type": "object" }
} ] }
```

- `delivery` must contain `"poll"`, or the trigger is `noPollMode`.
- `inputSchema` is checked with the subset in [research R8](../research.md#r8-checking-the-arguments-against-inputschema).
- `payloadSchema` is not enforced. Payloads are untrusted data whatever they say.

## `events/poll`

Request:

```json
{ "name": "checks.failed", "arguments": { "repo": "alexec/Agents" }, "cursor": null, "maxEvents": 50 }
```

Response used:

```json
{ "events": [ { "eventId": "checks.failed:alexec/Agents:123:2", "name": "checks.failed",
               "timestamp": "2026-10-06T12:05:00Z", "data": { } } ],
  "cursor": "opaque", "truncated": false, "hasMore": false, "nextPollMs": 30000 }
```

| Field | What the daemon does |
|---|---|
| `events[].eventId` | Dedupe key, required. An event without one is dropped and logged. |
| `events[].name` | Must equal the requested name, or the event is dropped and logged. |
| `events[].data` | Goes in `details.payload` (R7). |
| `cursor` | Saved (R4). `null` keeps the previous one. |
| `truncated` | Sets `missedSince`. |
| `hasMore` | Polls again at once, up to 10 pages in a row. |
| `nextPollMs` | Clamped to the range 10 000–300 000 ms. 30 000 if absent. |

## Errors

| Code | Meaning | State |
|---|---|---|
| `-32011` NotFound | Event gone | `stopped` / `eventNotOffered` |
| `-32012` Forbidden | Not allowed | `stopped` / `refused` |
| `-32013` ResourceExhausted | Rate limited | `retrying`, honouring `data.retryAfterMs` if given |
| `-32014` Unsupported | With `data.reason: schema_changed`, list again and recheck. Otherwise `stopped` / `serverError`. | |
| `-32602` invalid params | Bad arguments the local check missed | `stopped` / `badArguments` with the server's message |
| Transport, timeout (15 s), 5xx | | `retrying` |
| 401/403 over http | | `needsSignIn` |

## Log lines (`daemon.log`)

The daemon logs only these. It never logs URLs, headers, payloads or arguments' values.

```
mcp events: ci connected (events: 2)
mcp events: ci checks.failed subscribed for <workflow ids> (key 3f9a…)
mcp events: ci checks.failed evt <eventId> raised (position 1234, workflows: fix-failed-checks)
mcp events: ci checks.failed truncated (events may have been missed)
mcp events: ci checks.failed retrying in 40s (unreachable)
mcp events: ci checks.failed stopped (eventNotOffered)
```
