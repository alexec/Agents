# Contract: what we send the runtimes, and what we must answer

> **Superseded by [`specs/003-acp-coverage/contracts/acp-client.md`](../../003-acp-coverage/contracts/acp-client.md).**
> This one covers the subset 001 needed. In particular, 001's decision to advertise no
> client file or terminal capabilities was reversed on 2026-09-18.

**Feature**: [spec.md](../spec.md) | **Evidence**: [research.md](../research.md)

Line-delimited JSON-RPC 2.0 over the runtime's stdin and stdout. One object per line, no headers.
Protocol version 1. Everything below was exercised against Copilot 1.0.86, Grok 1.0.34 and
`@agentclientprotocol/claude-agent-acp` 0.78.0 on 2026-09-18.

## What we call

### `initialize`

```json
{"protocolVersion": 1,
 "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}}
```

We advertise nothing (plan, decision 8). From the reply we keep:

- `agentCapabilities.sessionCapabilities` — the presence of `resume` decides resume vs load.
- `agentCapabilities.loadSession` — must be true or the agent cannot be picked up at all.
- `agentInfo.name` / `.version` — shown, and worth logging when something misbehaves.
- `authMethods` — shown only when a session cannot be created. Their presence proves nothing:
  Copilot advertises `copilot-login` while perfectly signed in.

Anything in `_meta` is ignored. That is the rule that keeps one code path.

### `session/new`

```json
{"cwd": "<absolute path>", "mcpServers": []}
```

`sessionId` comes back and is recorded against our agent. A `sessionId` we send is ignored by all
three, so we never send one.

`configOptions` comes back with it and is the whole of the start form (data-model: ConfigOption).
`models` and `modes` also arrive from some runtimes and are ignored: they are inconsistent between
the three and the protocol is retiring them.

### `session/prompt`

```json
{"sessionId": "...", "prompt": [{"type": "text", "text": "..."}]}
```

Returns when the turn ends, with `stopReason`: `end_turn`, `max_tokens`, `max_turn_requests`,
`refusal` or `cancelled`. That reply, and only that reply, ends the turn. It maps straight onto
EndedReason.

### `session/cancel`

A notification. Sent when the user stops an agent. The in-flight `session/prompt` then returns
`cancelled`, and we wait for it before closing.

### `session/close`, then terminate

An agent is ended in that order (FR-011b): cancel if a turn is running, close the session, terminate
the process, and only `SIGKILL` if it has not gone within a few seconds.

### `session/resume` or `session/load`

Both take `{"sessionId", "cwd", "mcpServers"}`. Resume restores and returns. Load replays the whole
conversation as `session/update` notifications first, and we discard the replay because we have our
own transcript.

Which one is decided by `sessionCapabilities.resume`, never by the runtime's name. Copilot answers
`-32601 Method not found` for resume, which is the advertised behaviour rather than a fault.

### `session/list`

Returns sessions for a `cwd`, each with `sessionId`, `cwd`, `title` and `updatedAt`. Not needed to
pick an agent up, since we keep the id. Used to tell "the runtime has lost this session" from "the
runtime is broken", which is the difference between FR-012d and an error.

### `session/set_config_option`

```json
{"sessionId": "...", "configId": "model", "value": "gpt-5.6-terra"}
```

The reply is the refreshed option list. Used at start, once the session exists, and whenever the
user changes something mid-session. The spelling was confirmed against Copilot and the Claude
adapter: `session/setConfigOption` and `session/set_option` are both method-not-found.

## What we must answer

The daemon is a JSON-RPC server too. These arrive as requests, and a request left unanswered leaves
the agent hanging.

### `session/request_permission`

The agent is blocked until we reply. It carries the tool call and a list of options, each with an
`optionId` and a `kind` saying whether it allows or rejects, once or always.

```json
{"outcome": {"outcome": "selected", "optionId": "<one of the offered>"}}
```

Rules, from FR-009a and FR-009b:

- Only the user chooses. Nothing in this feature answers on their behalf, remembers an answer, or
  applies a rule of its own. A runtime's own always-allow option is the user's to pick.
- A question that arrives with no window open is held, the agent stays alive, and the daemon does not
  exit while it waits (FR-019a).
- If the user stops the agent while it waits, the reply is `{"outcome": {"outcome": "cancelled"}}`.

### Anything else

Answered with `-32601 Method not found`. Every runtime asked us for something in the probes and
carried on being told no. Declining loudly beats going quiet.

## What we listen to

`session/update` notifications, appended to the transcript as they arrive rather than at turn end, so
that a daemon that dies mid-turn still leaves an honest record:

| Update | What we do |
|---|---|
| agent message chunk | Append, joined by the runtime's message id |
| agent thought chunk | Append, shown collapsed |
| tool call, and updates to it | Append; a status change updates the entry already recorded |
| plan | Append |
| current mode change | Update the agent's options |
| config option update | Update the agent's options |
| `session_info_update` | The runtime's own title for the session, which is what names the agent |
| `usage_update` | Ignored in this feature. It is what a cost feature will read later |
| `available_commands_update` | Ignored in this feature. Slash commands are a later one |

Unknown update types are logged once and skipped. A new update type in a runtime must never stop an
agent working.
