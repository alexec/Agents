# Contract: what the client answers, after Cursor

A delta against [003's acp-client contract](../../003-acp-coverage/contracts/acp-client.md). Nothing
here is new protocol. One rule changes, and it changes for every runtime.

## What we send: unchanged

The handshake, `session/new`, `session/prompt`, `session/load`, `session/list`, `session/cancel` and
the rest are exactly as 003 left them. Cursor is started as `cursor-agent acp` and is spoken to the
same way as Grok and Copilot.

`clientCapabilities` is unchanged. In particular the app does **not** advertise anything in `_meta` to
opt into a runtime's private extensions.

## What we answer: requests

Unchanged, and the table is here because the unchanged part is the contract.

| Inbound request | Answer |
|---|---|
| `session/request_permission` | The permission question, as 003 defined |
| `fs/read_text_file` | Served when the capability is advertised |
| `fs/write_text_file` | Served when the capability is advertised |
| `terminal/*` | Served when the capability is advertised |
| `elicitation/create` | A form or a URL, as 003 defined |
| **anything else** | `-32601`, message `Method not found`, `data: {"method": "<name>"}` |

That last row is the whole of this feature's handling of `cursor/create_plan` and
`cursor/ask_question`, and the evidence that it is right is in research section 3: a turn answered
this way runs to `end_turn`, and a turn left unanswered does not finish.

**The rule**: a request we do not recognise is declined immediately and explicitly. It is never left
open, and it is never answered with a guess. A runtime that sends a private method is expected to
have a path for a client that does not speak it, and Cursor does.

## What we answer: notifications

This is the one change.

| Inbound notification | Before | After |
|---|---|---|
| `session/update`, kind we know | Handled | Handled |
| `session/update`, kind we do not know | `unknownUpdate(kind)` event, one daemon log line | Unchanged |
| `elicitation/complete` | Withdraws the pending form | Unchanged |
| **any other method** | **Dropped silently** | `unknownNotification(method)` event, one daemon log line |

A notification needs no reply, so nothing is sent back either way. The difference is entirely whether
the app can tell you it happened.

**The rule**: nothing a runtime sends is discarded without a trace. A notification we cannot act on is
recorded as having arrived, named, once, in the daemon log. It does not reach the transcript, because
it is a fact about a runtime rather than part of a conversation.

## What we do not read

Stated so that a future reader does not mistake it for an oversight.

- `models` and `modes` on the `session/new` result. Not decoded for any runtime, by 003's decision.
  Cursor sends both and the app shows neither.
- Anything under a runtime's own namespace. There is no `cursor/` case anywhere, by design.

## Capability gates that now have a runtime exercising them

Cursor is the first runtime to take the "no" branch on several gates that three runtimes all passed.
No code changes; this is a note that these paths are now reachable in the live suite.

| Gate | Cursor |
|---|---|
| `supportsLogout` | false, so sign-out is not offered |
| `agentCapabilities.providers` | absent, so no provider picker |
| `sessionCapabilities.fork` / `delete` | absent, so neither is offered |
| `configOptions` on `session/new` | absent, so the start sheet shows no options |
| `promptCapabilities.embeddedContext` | false, so a file goes as a `resource_link` |

The last two are the ones worth watching: `configOptions` is asserted non-empty by a live test today,
which is why that assertion changes (research section 5).
