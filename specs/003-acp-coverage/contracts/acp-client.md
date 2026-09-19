# Contract: what we say to a runtime, and what we answer it

Supersedes `specs/001-agent-daemon-ui/contracts/acp-client.md`, which covered the subset 001 needed.
Protocol version 1. Every method below was checked against the published schema
(`@agentclientprotocol/sdk` 1.4.0) and, where a runtime on this Mac implements it, against that
runtime on 2026-09-18.

## What we advertise

```json
{
  "protocolVersion": 1,
  "clientCapabilities": {
    "fs": { "readTextFile": true, "writeTextFile": true },
    "terminal": true,
    "session": { "configOptions": { "boolean": {} }, "compaction": {} },
    "plan": {},
    "auth": { "terminal": true },
    "elicitation": { "form": {}, "url": {} }
  }
}
```

Rule: each flag goes true only once the thing behind it works, and a flag is never true for
something we would refuse. Grok stops doing its own file IO the moment `fs` is true, so this is a
promise, not a hint.

Rule: the agent's answer carries its own `protocolVersion`. If it is not 1, the app reports a
version it cannot speak and does not treat the session as healthy.

## Methods we call

| Method | When | Gated on |
|---|---|---|
| `initialize` | Every connection | Always |
| `authenticate` | The user chooses a sign-in method | `authMethods` was non-empty |
| `logout` | The user signs out | `agentCapabilities.auth.logout` |
| `providers/list`, `providers/set`, `providers/disable` | The user looks at or changes the provider | `agentCapabilities.providers` |
| `session/new` | Starting an agent | Always |
| `session/load` | Picking one up, no resume | `loadSession` |
| `session/resume` | Picking one up | `sessionCapabilities.resume` |
| `session/list` | Looking for sessions the app did not start | `sessionCapabilities.list` |
| `session/fork` | Branching an agent | `sessionCapabilities.fork` |
| `session/delete` | Deleting a session, after a confirmation | `sessionCapabilities.delete` |
| `session/close` | Ending an agent | `sessionCapabilities.close` |
| `session/prompt` | Sending a prompt | Always |
| `session/cancel` | Stopping a turn | Always (notification) |
| `session/set_config_option` | Changing a setting | An option was advertised |

Never called, and why: `session/set_mode` (the same setting arrives as a config option on all three,
and 001 chose the options list as the single surface), `mcp/message`, `nes/*`, `document/did*`,
`$/cancel_request`. Each is in the spec's Out of Scope section.

`additionalDirectories` is sent on `session/new`, `session/load`, `session/resume` and `session/fork`
where `sessionCapabilities.additionalDirectories` is advertised.

`mcpServers` carries what the user attached, in the transport shapes the agent advertised under
`mcpCapabilities`. Today all three accept `http` and `sse`; `stdio` is baseline.

## Prompt content

```json
{ "sessionId": "...", "prompt": [
  { "type": "text", "text": "..." },
  { "type": "image", "mimeType": "image/png", "data": "<base64>" },
  { "type": "resource_link", "uri": "file:///...", "name": "notes.txt" },
  { "type": "resource", "resource": { "uri": "file:///...", "text": "..." } }
] }
```

| Block | Sent when |
|---|---|
| `text` | Always |
| `resource_link` | Always. Baseline in the protocol |
| `image` | `promptCapabilities.image` |
| `audio` | `promptCapabilities.audio` |
| `resource` | `promptCapabilities.embeddedContext` |

Verified on 2026-09-18: the Claude adapter answered a prompt carrying an image block and one
carrying a resource link.

## Updates we read

All fifteen. `usage_update` moves from "ignored on purpose" to a meter.

| `sessionUpdate` | What we do |
|---|---|
| `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk` | Blocks, coalesced into one entry per message |
| `tool_call`, `tool_call_update` | Merged field by field; content appended |
| `plan` | Replaces the current unidentified plan |
| `plan_update` | Replaces or adds the plan with that id |
| `plan_removed` | Marks that plan withdrawn |
| `available_commands_update` | The slash command list |
| `current_mode_update` | Recorded against the agent |
| `config_option_update` | Replaces the option list |
| `session_info_update` | Title, and `updatedAt` |
| `usage_update` | Context meter, and cost when present |
| `compaction_update` | An entry saying it started, finished or failed |
| `compaction_summary_chunk` | Appended to that entry |
| anything else | Noted against the agent, never fatal |

## Requests we answer

001 answered one and declined the rest. This feature answers seven.

### `session/request_permission`

Unchanged, except that a `diff` in the tool call is now shown in the question.

### `fs/read_text_file`

```json
{ "sessionId": "...", "path": "/abs/path", "line": 1, "limit": 100 }
→ { "content": "..." }
```

Served when the path is inside the agent's folders. Recorded in the transcript. Not asked about: a
read is not a change, and Grok issues several per edit. `line` and `limit` are honoured.

### `fs/write_text_file`

```json
{ "sessionId": "...", "path": "/abs/path", "content": "..." }
→ {}
```

Goes through the permission question, with the change shown. Refused outside the agent's folders,
with a reason the agent can read. Written atomically.

### `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/release`, `terminal/kill`

```json
{ "sessionId": "...", "command": "echo", "args": ["hi"], "cwd": "...", "env": [{"name":"X","value":"1"}] }
→ { "terminalId": "..." }
{ "sessionId": "...", "terminalId": "..." }
→ { "output": "...", "truncated": false, "exitStatus": { "exitCode": 0, "signal": null } }
```

The process is a child of the daemon, its `cwd` must be inside the agent's folders, its output is
kept to a byte cap with truncation flagged, and it is killed when the agent stops or the daemon
exits. Verified on 2026-09-18: Grok used the full lifecycle (create, wait_for_exit, output, release)
in a single small edit-and-run turn.

### `elicitation/create`

```json
{ "sessionId": "...", "elicitationId": "...", "mode": "form", "schema": { ... } }
→ { "action": "accept", "content": { ... } }   // or { "action": "decline" } / { "action": "cancel" }
```

Held like a permission question: survives no window being open, answerable from any window. The
answer is validated against the schema before it is sent. A schema the app cannot draw is declined
rather than half-answered.

### `elicitation/complete`

The notification that an elicitation is finished elsewhere. The form is withdrawn.

### Everything else

Declined with `-32601`, as before. That is now a short list: `mcp/connect`, `mcp/message`,
`mcp/disconnect`.

## Errors

| Code | Meaning | What the app does |
|---|---|---|
| `-32601` | Method not found | Expected where a capability was not advertised. Not an error to show |
| `-32000` | Authentication required | The runtime is marked as needing sign-in and the agent shows the way to fix it |
| `-32002` | Resource not found | Shown against the action that asked |
| `-32800` | Request cancelled | Expected after a cancel. Not an error to show |
| anything else | Whatever the agent said | Shown against the action, agent left alive |

`-32000` is the one the app has never seen, because no runtime here is signed out. It is proved
during implementation by signing one out, not by guessing.
