# Go agentsd spike (#1125): report

Throwaway code in `agentsd-go/`. Not for merge. The test note is [test.md](test.md).

## Stages

| Stage | Status | Commit | What works |
|---|---|---|---|
| 1. Base | done (socket); window look waits for an unlocked screen | (this commit) | Joins with a v2 host code over today's wire. A real Claude turn over `coder/acp-go-sdk`, with this Mac's sign-in lent through the control plane. |

## Stage 1: the base

**What was done**
- **The join.** The Go host enrols with a v2 host code (`e:<id>`, `hosts/announce`), then dials as `h:<host>` with the HKDF(ECDH) key. The HMAC exchange is `hello`/`auth`/`ok`, and the certificate is pinned by SPKI SHA-256. It says `host/hello` on channel 0 and serves every channel the control plane opens as a daemon connection. The scratch control plane lists it as `devbox (Go)`, `Linux arm64`, `0.1.0-go`, online. It joined at the first try; nothing in the Swift had to change.
- **The daemon side.** Each channel is JSON-RPC 2.0, one line per message. The Go host answers what the window calls on a server host:
  - `daemon/ping`, `runtimes/list`, `projects/list|add|remove`;
  - `agents/list` (lean, paging, `agentID`), `agents/start|prompt|stop|archive|setUnread`, `agents/transcript`, `agents/turns` (empty, which the window handles);
  - `agents/options` (an empty draft), `permissions/pending|answer`, `elicitations/pending`;
  - no-op stubs for the settings pushes, `presence/report` and `credentials/offer`.
  It sends `agent/changed`, `agent/entry`, `agent/permission`, `agent/usage` and `project/changed`.
- **The turn.** `coder/acp-go-sdk` v0.13.5, unforked: `initialize` → `session/new` (with Claude's `_meta` tool policy) → `session/prompt`. The ACP updates become today's transcript records: `agentMessage`/`agentThought` by `messageID`, `toolCall`/`toolCallUpdate` with `toolCallID`, `planUpdated`, `permissionAsked`/`permissionAnswered`, `stateChanged`, `usageRecorded`. The ending is `finished`/`endTurn` with a report taken from the last words, as `DaemonCore+DerivedEnding` does.
- **The sign-in.** There is no Claude sign-in on the box. On `agents/start` the Go host answers `-32036 credentialWanted`, as the Swift host does. The window (here `agentsctl`, doing what `Lending.swift` does) then calls `hosts/lendSignIn` → `relay/grant` on `mac` → `relay/offer` on the Go host. The Go host opens a loopback gate and carries each connection through `tunnel/open`, as base64 lines. TLS ends on the Mac. The proof is a real 200 from Anthropic through Alex's Mac sign-in.
- **The toolset.** Nobody installs Claude's toolset on a control-plane host today. The 043 installer is not reached (see the notes). I installed the pinned Node v24.21.0 and `claude-agent-acp` 0.81.2 by hand on the box in `~/.agents-go/tools/claude/current`, with today's layout and shim.

**Proof** (2026-10-16 00:40, devbox + scratch control plane `run-go1125`)
```
$ agentsctl turn -host k3rs7zgm -runtime claude -cwd /home/agents/src/hello "Read README.md and say in one sentence what it is…"
the host wants a sign-in (-32036); lending it, as the window does
mac lends claude's sign-in to k3rs7zgm
[userMessage] … [stateChanged] running … [runtimeNote] Starting Claude…
[toolCall] Read File … [toolCallUpdate] … File does not exist …
There's no README.md in /home/agents/src/hello — the file doesn't exist.
[usageRecorded] {"inputTokens":4,"outputTokens":90,"totalTokens":66542}
== finished (endTurn) {"outcome":"done","message":"There's no README.md …"}
```
The window was connected to the Go host the whole time (its `refreshServer` calls are in the Go host's log). The screen was locked, so a screenshot of the window had to wait.

**What had to be written by hand to match the Swift wire.** Everything; there is no shared schema today. About 300 lines of auth, join and uplink (`internal/control`), and the records the window reads (`internal/daemon/model.go`).
- Swift's encoder: `Date` is seconds since 2001, `Data` is standard base64, UUIDs are upper case. Enums with associated values are `{"case":{"_0":…}}`, so `kind` in a transcript entry is an object with one key.
- An unknown `endedReason` fails the whole agent on the window: no lenient decode.
- `Web/src/protocol/generated.ts` and the Swift fixtures were the best checks.

**acp-go-sdk: what it covers of what AgentsKit uses**
- **Covered, typed:** `initialize` (with client capabilities), `authenticate`, `session/new|load|resume|list|close|fork|delete`, `session/prompt`, `session/cancel`, `session/set_mode` and `session/set_config_option`.
  - Agent → client: `session/request_permission`, `fs/read_text_file|write_text_file`, all five `terminal/*` and every `session/update` kind, including `plan`, `usage_update`, `config_option_update`, `current_mode_update`, `available_commands_update` and `session_info_update`.
  - MCP servers in `session/new` (stdio, http and sse), and `_meta` on every type.
  - Notifications are ordered before the prompt's reply.
- **Not typed, but reachable:** the vendor methods AgentsKit uses (`_session/steering`, `_session/async_task/stop`, `_x.ai/billing`) go through `CallExtension`/`NotifyExtension`. Incoming `_auth/status_update` and `_x.ai/session_notification` need the extension handler. The JetBrains AIR updates (`async_task_*`, `subagent_*`), compaction and notices are not in the SDK's union, so they arrive as unknown kinds.
- **Missing:** nothing that stopped a Claude turn. No fork was needed.

**Build** (this Mac, `golang:1.25` in Colima, linux/arm64, `CGO_ENABLED=0 -trimpath -ldflags "-s -w"`)

| | Go `agentsd` | Swift `agentsd` |
|---|---|---|
| Binary, Linux arm64 | 6.4 MB | 78 MB (`agentsd-linux-aarch64`, static) |
| Binary, Linux x86-64 | 6.9 MB | 83 MB |
| Cold build (modules cached) | 13 s | the Swift static-SDK cross-build (not timed again here) |
| Rebuild | under 1 s | |

**Libraries:** `coder/acp-go-sdk` v0.13.5, `coder/websocket` v1.8.15, and the standard library's `crypto/ecdh`, `crypto/hkdf`, `crypto/hmac` and `crypto/tls`. The pin is `VerifyPeerCertificate` over the leaf's SPKI. Nothing was missing.
