# Go agentsd spike (#1125): report

Throwaway code in `agentsd-go/`. Not for merge. The test note is [test.md](test.md).

## Stages

| Stage | Status | Commit | What works |
|---|---|---|---|
| 1. Base | done (socket); window look waits for an unlocked screen | 3acff3f2 | Joins with a v2 host code over today's wire. A real Claude turn over `coder/acp-go-sdk`, with this Mac's sign-in lent through the control plane. |
| 2. Everyday turn | done (socket); window look waits | 91657767 | Permission cards both ways; the app's tools (`list_sessions`, `read_session`, `start_session`) on `modelcontextprotocol/go-sdk`; terminals on `creack/pty`; files browse/list/read/write; Codex with the Mac's ChatGPT sign-in lent; stop. |
| 3. Schema-first wire | done | (this commit) | `schema/daemon.schema.json`, 118 definitions, with Go, Swift and TypeScript generated from it. Go and Swift round-trip all 316 records today's Swift encoder writes in the fixtures. Today's TypeScript types fit the schema's. The Go host's own records fit it too. |

## Stage 3: a schema-first wire

**What was done** (`agentsd-go/schema/`; `bootstrap.sh`, `gen.sh` and `check.sh` remake and check all of it)
- **The schema.** `daemon.schema.json` is JSON Schema draft-07: 118 definitions, everything reachable from the 11 types stages 1–2 put on the wire (`Agent`, `TranscriptEntry`, `TranscriptPage`, `TurnsPage`, `ProjectSummary`, `RuntimeStatus`, `PermissionRequest`, `ListRequest`, `StartRequest`, `PromptRequest`, `OptionsResponse`).
  - It was not typed by hand. `Packages/WebTypes` already reads the Swift source into `Web/src/protocol/generated.ts`, and `ts-json-schema-generator` turned all of that into a schema: every one of the 364 exported types, as 361 definitions with none missing (3 are aliases).
  - So the first schema is today's Swift exactly. From here the schema would be the source, and WebTypes would go.
- **Go** (`atombender/go-jsonschema` v0.24.1, into `internal/wire/types_gen.go`, 2925 lines). An enum with associated values (`anyOf` of one-key objects) becomes a struct of optional pointers, one per case. That reads and writes Swift's `{"case":{…}}` as it is.
  - One fix after generation: a case with no values (`{"timedOut":{}}`) was typed as a map, and `omitempty` dropped it. `gen.sh` makes those fields pointers.
- **Swift** (quicktype 23, into `swift-check/Sources/WireTypes/Wire.swift`, 9.4k lines) and **TypeScript** (quicktype, `ts/wire.ts`, 1.2k lines).
  - quicktype overflows its stack on the recursive `JSONValue`, so it reads a copy where `JSONValue` is "any".
  - Its `JSONAny` cannot be `Equatable`.
  - Its names are poor where the TS had none (`WPurpleConfigChoice`).
- **Checks** (`check.sh`), all passing:
  - **Go:** the 316 Agent, TranscriptEntry, RuntimeStatus and PermissionRequest records in AgentsKit's Swift-encoded fixtures decode with unknown fields refused, and encode back to the same JSON (`internal/wire/roundtrip_test.go`). 310 passed before the empty-case fix and 316 after.
  - **Swift:** `swift-check` depends on `Packages/AgentsKit` and changes none of it. Each fixture is decoded into today's `AgentsKitCore` type and encoded with today's encoder (a plain `JSONEncoder`, as `JSONValue.encoding` uses). That output is decoded into the generated `W…` type and encoded again: 316 of 316 are the same.
  - **The Go host's own records** (an agent; 11 entry kinds, from text to permissions; a project; the runtimes) decode strictly into the generated Go (`internal/daemon/schema_test.go`).
  - **TypeScript:** `tsc --strict` checks that every one of the 11 types in today's `generated.ts` can be assigned to the type made from the schema. The reverse does not hold (see below).

**How much of `DaemonAPI` and `Model` a schema can carry**
- **All of the shapes.** Every type the web page reaches, which is every one a client reads, went into the schema with nothing left out: records, requests, results, string enums, enums with associated values, optional against required, `[AgentGroup: Int]` maps, and nesting and recursion (`JSONValue`).
- **It cannot carry these:**
  - **What a value means.** `Date` is seconds since 2001, `UUID` is upper case, `Data` is base64 and a file `URL` is a URL. In the schema they are a number and strings, with a description, a `format`/`pattern` for UUIDs and an `x-swift-type`, and no generator reads those. The generated Swift has `Double` and `String` where the product has `Date`, `UUID` and `URL`; the Go has `float64`. A real switch needs a type map for the generators, or small hand-written types for these five.
  - **Decoders that forgive.**
    - `TranscriptEntry`'s unknown kind is kept as `unrecognised`; `AgentState`'s unknown value reads as `stopped`.
    - `WorkflowSummary` defaults most of its fields.
    - `EndedReason` has no forgiving decode: an unknown value fails the whole agent.
    A schema can say "one of these, or anything else" (`anyOf` with a fallback), but generated code does not then *do* what the hand-written `init(from:)` does.
  - **Which method takes what.** The schema has types, not methods: nothing says `agents/start` takes a `StartRequest` and answers a UUID, or which notifications exist. OpenRPC (a JSON Schema document per method) is the standard way to add that. `DaemonAPI.WebSignatures` already lists the methods.
  - **Behaviour.** The lean `agent/changed`, `index`/`oversized` on `agent/entry`, paging rules, the error codes and their meaning, and the order of a turn's notifications. These are rules in prose, not shapes.
- **The TypeScript the schema gives is wider than today's.** `UUID`, `WireDate` and `Base64` are branded types in `generated.ts` and plain `string`/`number` in `wire.ts`. So today's types fit the schema's, but not the other way round. The brands would need a hand-written prelude, as `generated.ts` has.

**Verdict:** a schema carries the wire's shapes completely, and three generators turned it into working Go, Swift and TypeScript in a day, checked against today's encoder. The cost is the five meaning-types, the forgiving decoders and the method list. Those are small and hand-written once. I would make the schema the source for a Go control plane and hosts, with OpenRPC for the methods, and keep Swift `Model` types hand-written but checked against the schema in CI (as `swift-check` does) rather than generated.

## Stage 2: an everyday turn on Linux

**What was done** (all proved through the scratch control plane with `agentsctl`, 2026-10-16 00:42–00:58)
- **Cards.** A tool call that needs permission becomes a `permissionAsked` entry, `waitingOnUser`, and `agent/permission` with the request. `permissions/pending` lists it. `permissions/answer` sends the chosen `optionId` back to the runtime over ACP, records `permissionAnswered` and goes back to `running`. The app's own `mcp__agents__*` tools are allowed with no card, as in Swift. A stop (`agents/stop`) cancels over ACP and ends `stopped`/`cancelled`; open cards are cancelled.
- **The app's tools** on `modelcontextprotocol/go-sdk` v1.8.0:
  - Streamable HTTP on loopback at `/mcp/agents`, with JSON replies. Each runtime gets its own bearer token, bound to its agent; an unknown token gets 404. It is handed to the runtime only in `session/new`'s `mcpServers`, as `{"type":"http","name":"agents",…}`.
  - `list_sessions`, `read_session` and `start_session`. Claude called all three in one turn, and the session it started ran and said "pong".
  - The SDK is a good fit: `mcp.AddTool` with typed inputs makes the JSON Schema from Go structs. `NewStreamableHTTPHandler`'s per-request `getServer` makes "which agent is calling" one map lookup.
- **Terminals** on `creack/pty` v1.1.24, as `ShellSession.swift` runs them:
  - `shell/attach|open|list|input|resize|detach|close|restart|signal` run `$SHELL -l` in the agent's or the project's folder, with a 4 MiB scrollback.
  - `shell/output` carries base64 bytes with `offset`. A reattach with `since`+`startedAt` replays only what is new. `shell/stateChanged` reports `exited` or `released`.
  - Proved: typed `echo hello-from-$(uname -s) && pwd`, read back `hello-from-Linux` and `/home/agents/src/hello`; closed, and heard `released`.
  - The project shell (Control-`) is keyed by the id the window makes from the folder. The Go host takes that id as given when `folder` names a project, so it does not reimplement the FNV-1a id.
- **Files:** `files/list` (folders first, 5000 at most), `files/read` (text up to 128 KiB, images up to 4 MiB, other, and `unchanged` by stamp), `files/browse` (for Add Project, `~` allowed), `files/write` (attachments into `.agents/attachments`), `files/readText|saveText` and `files/mention`. Reads are kept to the agent's folder, with symlinks resolved (`/etc/passwd` → -32602). `files/watch` is a no-op; no `files/changed` is sent yet.
- **Codex.** I installed the pinned `codex-acp` 1.13.1 by hand, as for Claude. The Go host asks for Codex's sign-in with -32036, as it does for Claude; the Swift host never does (`ServerSignIn.exists("codex")` is always true). The lend then worked unchanged: `relay/grant {runtime:"codex"}` on the Mac and `relay/offer` on the Go host. The Go host writes `CODEX_HOME` (`config.toml` with `chatgpt_base_url` at the gate, and the stand-in `auth.json`) and `CODEX_CA_CERTIFICATE`.
  - A real Codex turn ran `ls` and answered. As far as I know this is the first run of the Codex relay through a control plane.
  - Codex's own `bwrap` sandbox cannot make namespaces in the container, so Codex fell back to asking. That is the container's limit, not the host's.

**Known gaps in stage 2**
- No `files/changed` and no watches: the Files pane does not refresh by itself.
- No elicitations: question forms from Claude's AskUserQuestion or Codex's request_user_input are not served, and `elicitations/pending` is `[]`.
- No `agent/terminalOutput` for ACP terminals.
- The project shell's id is not checked.
- The relay offers live in memory, as in Swift: after the Go host restarts, the window has to lend again. It does that by itself on -32036.

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
