# Contract: the MCP bridge (stdio servers over loopback http)

What a runtime that refuses stdio servers from the client (Copilot, research R9) is given in
place of each stdio server, and what `agentsd` promises on the other end. Design: research R11.

## In `session/new` / `session/load`

A stdio server

```json
{ "name": "github", "command": "npx", "args": ["-y", "…"], "env": [{ "name": "GITHUB_TOKEN", "value": "…" }] }
```

is sent to Copilot as

```json
{ "type": "http", "name": "github",
  "url": "http://127.0.0.1:52811/mcp/Qm4…Xw",
  "headers": [{ "name": "Authorization", "value": "Bearer 7f…c2" }] }
```

The name is the same, so the tool names the model sees are the same as on every other runtime.

## HTTP

| Request | Answer |
|---|---|
| `POST /mcp/<id>` with the right bearer and a JSON-RPC request | `200 application/json`: the server's response with the same `id` |
| `POST /mcp/<id>` with the right bearer and a notification (no `id`) | `202`, empty |
| `POST` to an ended route, an unknown id, or without the right bearer | `404`, empty; the same answer whichever it is |
| `GET /mcp/<id>` | `405` |
| `DELETE /mcp/<id>` with the right bearer | `200`; the route ends and its process is stopped |
| a chunked request body | `411` |
| a body over 16 MiB | `413` |

- The listener binds `127.0.0.1` only.
- Connections may be kept alive and carry several requests. Requests on one route may overlap;
  each is answered as its `id` comes back.
- No timeout on a waiting request. A request still waiting when its route ends gets a JSON-RPC
  error, `-32000` "The agent's session has ended."
- If the server process exits, every waiting request gets `-32000` "The server stopped."; the next
  `POST` starts it again.
- Messages the server starts itself are not forwarded (v1): a notification is dropped and
  counted, and a request is answered with `-32601` by the bridge.

## Lifetime

A route is made with the session's app token and ends when that token is dropped: the agent is
stopped, archived or replaced by a new session, or its draft is let go. The route's process is
started on the first `POST`. It is sent `SIGTERM` when the route ends, and `SIGKILL` 2 s later if
it is still running. Every route ends when the daemon exits.

## Logging

`bridge: route <id prefix> for <server name> made | started (pid) | ended (reason) | dropped N
notifications`. Command lines, args, env, headers and bodies are never logged (FR-023).
