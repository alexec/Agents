# Contract: daemon methods for starting from a remote

JSON-RPC over `daemon.sock`, the direct link and (when 013 Track A lands) the relayed link, all
carried by `DaemonClient`. Names follow `DaemonAPI.Method`. Everything here is additive: a
caller that sends none of the new fields behaves exactly as before.

## Changed: `agents/start`

Params: `StartRequest`, with one new optional field.

```json
{
  "runtimeID": "claude-code",
  "cwd": "file:///Users/alex/Agents/",
  "prompt": "Look at the flaky stop test",
  "attachments": [],
  "startOptions": { "values": { "mode": "plan" } },
  "draftID": "…",
  "requestID": "6F1C…"
}
```

| Rule | Detail |
|------|--------|
| Same `requestID` twice | The second call returns the first call's agent id and starts nothing. Holds while the first call is still in flight (the second waits for it) and after a daemon restart (found through `Agent.startRequestID`). |
| `requestID` absent | Today's behaviour, unchanged. |
| A refused start | Nothing is recorded against the `requestID`, so a retry after the cause is fixed can start. |
| Mode memory | On success, if `startOptions.values` holds the runtime's mode option, it is written to mode memory and `modes/changed` is broadcast. |
| Errors | Unchanged codes and messages: `dayLimitReached`, `agentLimitReached`, `folderGone`, `runtimeNotFound`. A remote shows `message` as it is. |

Result: the agent's `UUID`, as today.

## Changed: `agents/options`

Unchanged params and result. The daemon now records the calling connection on the draft, and
ends the draft 30 s after that connection goes unless it has been used.

## New: `agents/discardDraft`

Params: `{ "draftID": "…" }`. Result: `{}`.

Ends the draft's runtime session. A draft already used, already ended or never known is not an
error: discarding is what the caller wanted, and it is so.

## New: `modes/remembered`

Params: none. Result: the whole memory, as a map.

```json
{ "claude-code": "plan", "codex": "auto" }
```

A runtime with no entry is absent. An entry that does not decode is absent from the result and
left in the file.

## New: `modes/import`

Params: `{ "modes": { "<runtimeID>": <JSONValue> } }`. Result: the memory after importing, as
`modes/remembered` returns it.

Fills gaps only: a runtime that already has an entry keeps it. Sent by the Mac app once per
connection, from its `prompt.mode.*` keys. Broadcasts `modes/changed` if anything was filled.

## New notification: `modes/changed`

Params: the whole memory, as `modes/remembered` returns it. Broadcast after any write. Clients
hold the latest copy in `AgentsModel` so that reading a remembered mode stays synchronous where
the Mac reads it today.

## Changed: `agents/setOption`

Unchanged params and result. When the option is the agent's mode option
(`ModeMemory.modeOption(in:)` over the agent's advertised options) and the runtime accepts the
change, the value is written to mode memory and `modes/changed` is broadcast. The Mac stops
writing `UserDefaults` for this.

## Changed: `Agent` on the wire

`startRequestID: UUID?`, present on agents started with a `requestID`. Read-only.
