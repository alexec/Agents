# #186 — What a runtime tells the app about an MCP tool's `ui://` view

Probed 2026-10-03 for the MCP Apps plan (#185 → **#186** → #187 → #188 → #189 → #190 → #191),
against [SEP-1865, 2026-01-26](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).

## Method

The 054 probe, extended ([`probe/mcp-server.py`](../054-user-dotagents/probe/mcp-server.py)
`--apps`, driven by [`probe/apps.py`](../054-user-dotagents/probe/apps.py) through
`run.sh apps-setup` and `run.sh apps <runtime>`). In `--apps` mode the probe server adds:

- a tool `<tag>_weather` whose definition carries
  `_meta: {"ui": {"resourceUri": "ui://<tag>/weather", "visibility": ["model", "app"]}, "ui/resourceUri": …}`
  (the flat key is the spec's deprecated spelling, still sent by SDKs);
- the resource `ui://<tag>/weather`, `text/html;profile=mcp-app`, in `resources/list` and `resources/read`;
- a result with all three parts: `content` text `KITE-WEATHER <city>: 21C, clear`,
  `structuredContent` `{city, temperatureC, conditions, probe: "STRUCTURED-4"}`, and
  `_meta` `{probe: "RESULT-META-5", ui: {resourceUri}}`.

It offers the tool whatever the client advertises, so a runtime that does not negotiate the
extension still shows what it does with the `_meta`. Every MCP message both ways is logged in
full (`PROBE_WIRE`), which is where a runtime's `initialize` capabilities show.

Each runtime was started as the app starts it (`RuntimeCatalog`; OpenCode with
`RuntimeLaunch`'s own `TMPDIR`), with `HOME` a scratch home at `/tmp/mcp-apps-probe/home`.
Nothing touched the live app or `daemon.sock`. Each session got two copies of the server:
`kite-apps` over http, and `heron-apps` over stdio (not for Copilot, which refuses stdio from a
client, 054 R9). The model was asked to call each weather tool once and to say what it saw. Runs
were one after another, 5 s apart.

The full wire logs are in [`186-mcp-apps-acp-probe/`](186-mcp-apps-acp-probe/):
`<runtime>.acp.jsonl` (every ACP line), `<runtime>.mcp.jsonl` (every MCP message) and
`<runtime>.json` (the summary). Local paths are replaced with `<repo>` and `<home>`.

## Versions

| Runtime | Adapter (ACP `agentInfo`) | Runtime as MCP client (`clientInfo`) | Model |
|---|---|---|---|
| Claude | `@agentclientprotocol/claude-agent-acp` 0.81.2 | `claude-code` 2.1.280 | default |
| Codex | `@agentclientprotocol/codex-acp` 1.13.1 | `codex-mcp-client` 0.156.1 | gpt-6-astra[low] |
| Copilot | Copilot 1.0.92-3 (built in) | `copilot-cli` 1.0.92-3 | claude-sonnet-5 |
| OpenCode | OpenCode 1.18.33 (built in) | `opencode` 1.18.33 | opencode/big-pickle |

**Not probed, out of the pool (2026-10-03):** Grok, Cursor, Gemini, Antigravity.

## Answers

| Runtime | 1. Server and tool named? | 2. Tool's `_meta` / `ui.resourceUri`? | 3. Result's `structuredContent` / `_meta`? | 4. Negotiates `io.modelcontextprotocol/ui`? |
|---|---|---|---|---|
| Claude | **yes, exactly**: `title` and `name` `mcp__kite-apps__kite_apps_weather`, also `_meta.claudeCode.toolName` | **no** | **`structuredContent` only, as a JSON string**, and it *replaces* the text: `content`, `rawOutput` and `_meta.claudeCode.toolResponse` are all `{"city":"Paris",…}`; the `content` text and the result `_meta` are gone | **no** (`roots`, `elicitation`) |
| Codex | **yes, exactly**: `rawInput: {server, tool, arguments}`, title `mcp.kite-apps.kite_apps_weather`, `_meta.is_mcp_tool_call` | **no** | **yes, all of it**: `rawOutput.result` is the whole `CallToolResult` (`content`, `structuredContent`, `_meta`) | **no** (`elicitation`; stdio also `experimental.codex/auth-change`) |
| Copilot | **a joined title only**: `kite-apps-kite_apps_weather` (server `-` tool) | **no** | **`structuredContent` yes, `_meta` no**: `rawOutput.structuredContent`, and `content` text plus the JSON | **no** (`sampling`) |
| OpenCode | **a joined title only**: `kite-apps_kite_apps_weather` (server `_` tool) | **no** | **neither**: `content` text only; `rawOutput` is `{output, metadata: {truncated}}` | **no** (`roots`) |

Same answers for the http and the stdio copy on every runtime that took both.

Other things seen on the MCP side:

- **No runtime read the `ui://` resource.** Claude called `resources/list` (so it saw the
  resource listed) and never `resources/read`; the others never asked for resources at all.
- **Claude and Copilot send `server/discover` first** over http, before `initialize`. The probe
  answered `-32601` and both went on. #185's server must do the same rather than fail.
- **No runtime advertised any extension** in ACP either: nothing about UI in
  `agentCapabilities`, and no `ui` key anywhere in the ACP logs except Codex's copy of the
  result's `_meta`.

## Excerpts

Claude, the result (`claude.acp.jsonl`): the text `KITE-WEATHER Paris: 21C, clear` that the
server sent is not there.

```json
{"sessionUpdate": "tool_call_update", "toolCallId": "toolu_01WZMPy8QiKs1YZVC9abq67B", "status": "completed",
 "_meta": {"claudeCode": {"toolName": "mcp__kite-apps__kite_apps_weather"}},
 "rawOutput": "{\"city\":\"Paris\",\"temperatureC\":21,\"conditions\":\"clear\",\"probe\":\"STRUCTURED-4\"}",
 "content": [{"type": "content", "content": {"type": "text", "text": "{\"city\":\"Paris\",\"temperatureC\":21,\"conditions\":\"clear\",\"probe\":\"STRUCTURED-4\"}"}}]}
```

Codex, the call and its result (`codex.acp.jsonl`):

```json
{"sessionUpdate": "tool_call", "toolCallId": "exec-5eb8d72d-…", "kind": "execute", "title": "mcp.kite-apps.kite_apps_weather",
 "rawInput": {"server": "kite-apps", "tool": "kite_apps_weather", "arguments": {"city": "Paris"}}, "_meta": {"is_mcp_tool_call": true}}
{"sessionUpdate": "tool_call_update", "toolCallId": "exec-5eb8d72d-…", "status": "completed",
 "rawOutput": {"result": {"content": [{"type": "text", "text": "KITE-WEATHER Paris: 21C, clear"}],
   "structuredContent": {"city": "Paris", "temperatureC": 21, "conditions": "clear", "probe": "STRUCTURED-4"},
   "_meta": {"probe": "RESULT-META-5", "ui": {"resourceUri": "ui://kite-apps/weather"}}}, "error": null}}
```

Copilot (`copilot.acp.jsonl`):

```json
{"sessionUpdate": "tool_call", "toolCallId": "toolu_018Kjowavipcwwzg82Xr6fwH", "title": "kite-apps-kite_apps_weather", "kind": "other", "rawInput": {"city": "Paris"}}
{"sessionUpdate": "tool_call_update", "toolCallId": "toolu_018Kjowavipcwwzg82Xr6fwH", "status": "completed",
 "rawOutput": {"content": "KITE-WEATHER Paris: 21C, clear\n\n{\"city\":\"Paris\",…}", "contents": [{"type": "text", "text": "KITE-WEATHER Paris: 21C, clear"}],
   "structuredContent": {"city": "Paris", "temperatureC": 21, "conditions": "clear", "probe": "STRUCTURED-4"}}}
```

OpenCode (`opencode.acp.jsonl`):

```json
{"sessionUpdate": "tool_call_update", "toolCallId": "call_01a1051722a170dcad394248", "status": "in_progress", "title": "kite-apps_kite_apps_weather", "rawInput": {"city": "Paris"}}
{"sessionUpdate": "tool_call_update", "toolCallId": "call_01a1051722a170dcad394248", "status": "completed",
 "content": [{"type": "content", "content": {"type": "text", "text": "KITE-WEATHER Paris: 21C, clear"}}],
 "rawOutput": {"output": "KITE-WEATHER Paris: 21C, clear", "metadata": {"truncated": false}}}
```

Claude's `initialize` to the server (`claude.mcp.jsonl`); the others are the same shape, with
no `extensions` key:

```json
{"protocolVersion": "2025-11-25", "capabilities": {"roots": {"listChanged": true}, "elicitation": {}},
 "clientInfo": {"name": "claude-code", "title": "Claude Code", "version": "2.1.280"}}
```

## What it means

**No runtime tells the app that a tool has a UI.** None passes the tool definition's `_meta`,
none negotiates the extension, and none reads the resource. A runtime would only draw a view if
it were an MCP Apps host itself, and these four are not. So the app has to know which tools
have views from **its own copy of each server's tool list**, and pick out the server and the
tool from the ACP update:

- **Claude** and **Codex** name both exactly (`mcp__<server>__<tool>`; `rawInput.server/tool`).
- **Copilot** (`<server>-<tool>`) and **OpenCode** (`<server>_<tool>`) join them into a title,
  which is ambiguous in general (`kite-apps-kite_apps_weather`). It can be resolved against the
  server names the app itself put in `session/new` (longest name that is a prefix and owns that
  tool). The app's own server is `agents`, so `agents-` and `agents_` are unambiguous.

### For #187 (the app's own `agents` server): inline on all four

The daemon **is** the `agents` server. Every `tools/call` reaches it with the session's token
(the stdio helper's today, the bearer header after #185), so the daemon knows which session
called which tool, with which arguments, and the **whole result** it returned,
`structuredContent` and `_meta` included. It doesn't need the runtime to pass anything on. ACP
is needed only to place the view in the chat: match the `tool_call` (server and tool, parsed as
above) to the daemon's own record of the call, by session, tool name and order.

| Runtime | Inline view for an `agents` tool | `tool-input` / `tool-result` from |
|---|---|---|
| Claude | yes | the daemon's record (ACP has lost the text) |
| Codex | yes | the daemon's record (ACP also has it all) |
| Copilot | yes | the daemon's record |
| OpenCode | yes | the daemon's record |

So #187's "in the chat, for runtimes where #186 shows the app can tell" is **all four probed
runtimes**, provided the host keys views by the daemon's own record and not by anything in the
tool call. The out-of-pool runtimes should be checked when they come back.

### For #191 (third-party servers): depends on the runtime

The app has to be an MCP client for `resources/read` either way, and it then knows each
server's tool list and which tools have views. But it must never call a model's tool again
just to get its result (tools can have side effects), so `tool-result` has to come from ACP:

| Runtime | Inline third-party view | What the view gets |
|---|---|---|
| Codex | yes | the whole result |
| Copilot | yes | `content` and `structuredContent`, no `_meta` |
| Claude | yes, with a gap | `structuredContent` only (parsed from the JSON string); no `content` text, no `_meta` |
| OpenCode | **pinned only**, or inline with the text alone | `content` text only |

### For #188 (Dashboard as `ui://`): Claude's model sees the JSON, not the text

When a result has `structuredContent`, **Claude Code gives its model the JSON instead of the
`content` text** (the model quoted the JSON back as "the text the tool returned"). Codex and
Copilot give their models both, and OpenCode gives only the text. So `read_dashboard`'s
"text for the model plus `structuredContent` for the view" doesn't hold for Claude:
its `structuredContent` must read well to a model on its own and stay small. Trends of up to 120
points per tile go to the model every time Claude reads the Dashboard. Either keep trends out of
`structuredContent` (the view fetches them with an app-only tool), or accept the extra tokens
on Claude.

### Small things for #185

- Answer `server/discover` (and any unknown method) with `-32601`, as Claude and Copilot send
  it before `initialize`.
- Echoing `_meta.ui.resourceUri` in a result's `_meta` (the probe did) surfaces it on Codex
  only. That's not worth relying on, given the daemon's own record.
