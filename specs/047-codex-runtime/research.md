# Research: Codex as a Runtime

Measured on 2026-09-25 against `@agentclientprotocol/codex-acp@1.13.1` (npm `latest` that
day, published 14:05 UTC) and the `@openai/codex@0.156.1` it resolves to, on this Mac
(Apple silicon, Node v26.8.2). Codex is not installed here and nobody is signed in. Every
probe ran with `HOME=/tmp/codex-home` and npm's cache at `/tmp/codex-npm-cache`, so nothing
reached `~/.codex` or `~/.npm`. Anything below that needs a live, signed-in turn is marked
**to measure in the Phase 0 spike**, which needs Alex's ChatGPT sign-in once.

## R1. What runs, and why it is always the app's toolset

- **Measured**: codex-acp is a Node package (`bin: codex-acp → dist/index.js`, 1.5 MB), not
  a native program. It depends on `@openai/codex ^0.156.1`, whose `optionalDependencies`
  are npm aliases to six per-platform packages (`@openai/codex@0.156.1-darwin-arm64`, etc.),
  each carrying one native `codex` binary. `npm install --package-lock-only` for
  `codex-acp@1.13.1` gives a lock of 26 packages that includes all four platforms the app
  needs (darwin-arm64/x64, linux-arm64/x64), each with `os`, `cpu` and an `integrity` hash.
  `npm ci --ignore-scripts --omit=dev` from that lock took **4.7 s** here and installed
  only `codex-darwin-arm64`. That comes to 342 MB in `node_modules`, of which the binary
  (`vendor/aarch64-apple-darwin/bin/codex`) is 238 MB. The unpacked linux-x64 package is
  387 MB.
- **Decision**: Codex is a toolset runtime, shaped exactly like Claude's (043/048):
  - pinned Node v24.21.0 (the same pin as Claude's);
  - `package: @agentclientprotocol/codex-acp`, `packageVersion: 1.13.1`,
    `entry: dist/index.js`;
  - the lock above;
  - `minFreeBytes` of 1 GiB (about 520 MB unpacked, plus room).

  The app writes it with `scripts/update-toolset.sh codex v24.21.0 1.13.1`, a
  generalisation of `update-claude-toolset.sh` that checks the lock holds
  `codex-<platform>` for all four platforms.
- **Decision: never through the person's npx.** Claude's catalog entry is `npx -y …`, and
  discovery prefers the person's own `npx` on the PATH before the app's toolset. Codex does
  not do that. `Runtime` gains `usesAppCopyOnly` (default false, true for Codex; 046 adds the same field for Gemini), and its
  `executable` is `codex-acp`, the shim's name inside the toolset. There are three reasons:
  (1) D5: `npx -y codex-acp@1.13.1` resolves `@openai/codex` by a caret range, so two Macs
  could run different Codex binaries under the same app version; (2) FR-003: the 330 MB
  fetch would happen silently inside the first turn, where the app cannot show progress;
  (3) FR-002: a `codex-acp` of the person's on the PATH would otherwise win.
- **Alternatives**:
  - Claude's npx route: rejected, above.
  - A codex-acp native build from GitHub releases: there is none; the adapter is
    TypeScript.
  - Running the `codex` binary alone: it has no ACP mode; the adapter is what speaks ACP.
  - Sharing Claude's Node folder: see plan, Complexity Tracking.

## R2. Handshake: what Codex says about itself

`initialize` with the app's client capabilities (`elicitation.form` and `.url`,
`auth.terminal`), signed out, answered in about 1 s:

```json
{"protocolVersion":1,
 "agentInfo":{"name":"@agentclientprotocol/codex-acp","title":"Codex","version":"1.13.1"},
 "agentCapabilities":{"auth":{"logout":{}},"loadSession":true,
   "promptCapabilities":{"embeddedContext":true,"image":true},
   "sessionCapabilities":{"resume":{},"list":{},"close":{},"delete":{},"fork":{},
                          "additionalDirectories":{},"subagents":{}},
   "mcpCapabilities":{"acp":false,"http":true,"sse":false}},
 "authMethods":[
   {"id":"api-key","name":"API Key","_meta":{"api-key":{"provider":"openai"}}},
   {"id":"chat-gpt","name":"ChatGPT"},
   {"id":"chat-gpt-device-code","name":"ChatGPT (device code)"}],
 "_meta":{"steering":{"supported":true},"goal":{…},"jetbrains":{"air":{…}}}}
```

- **Resume (US1 #7)**: `loadSession` and `resume` both work through the existing path, so
  no "starts afresh" wording is needed.
- **Pictures**: `image: true`.
- **Sign-out (US2 #5)**: `auth.logout` is advertised, so the sheet's sign-out button
  appears through the existing capability check.
- **Subagents**: `sessionCapabilities.subagents` and the JetBrains "AIR" extensions (native
  subagent sessions, async tasks, goals) are only used by the adapter "after capability
  negotiation". The app advertises none of them, so they stay off (see R5 for the tools
  behind them).
- **MCP**: stdio servers (the README: "command-based stdio config") and HTTP. The app's MCP
  server goes in `session/new` `mcpServers` as for the other four. **To confirm in the
  spike** that its tools reach the model.

## R3. Not signed in, and what Codex writes

- `session/new` unsigned returned `{"code":-32000,"message":"Authentication required"}`.
  That is ACP's `authRequired`, which the daemon already turns into `needsSignIn` (FR-008).
  Nothing new is needed.
- Starting the adapter created `~/.codex/` in the scratch home, holding
  `installation_id`, several SQLite stores (`state_5`, `logs_2`, `memories_1`, `queue_1`,
  `goals_1`), `skills/` and `tmp/`. That is Codex keeping its own state, as it does from a
  terminal. FR-016 is about the app: the app writes none of it and never sets `CODEX_HOME`.
  SC-004's check compares `~/.codex/config.toml` and `~/.codex/auth.json`'s account, not
  the whole folder.

## R4. Signing in on the Mac

- The methods are `api-key`, `chat-gpt` (hidden when `NO_BROWSER` is set) and
  `chat-gpt-device-code` (offered because the app advertises URL elicitation).
  `RuntimeAccount.preferredMethod` today picks the first method without a terminal, which
  would be `api-key`. D1 wants ChatGPT first, so the runtime's policy entry gains an
  ordering hint (`preferredAuthMethods: ["chat-gpt", "chat-gpt-device-code", "api-key"]`),
  and the sheet shows that order. There is no id comparison in view code.
- **To measure in the spike**: that `authenticate {methodId:"chat-gpt"}` opens the browser
  from the adapter process (it depends on `open`) and completes with a local callback,
  writing `~/.codex/auth.json`, the same file `codex login` writes. Then Codex in a
  terminal is signed in too (US2 Independent Test). If the browser step cannot finish over
  ACP, the device-code method is the fallback: it arrives as a URL elicitation, which the
  app already shows as a link with a code.
- **Environment keys on the Mac**: `CODEX_API_KEY` and `OPENAI_API_KEY` in the login
  environment reach the adapter unchanged. Which sign-in wins is the adapter's business.
  The app neither adds nor strips a key on the Mac.

## R5. Tools, and taking some away

Codex's built-in tools come from feature switches in its config, not from a fixed list.
The switches found in the 0.156.1 binary's strings, and in the adapter, are these:

| Codex feature | Tools / behaviour | Decision |
|---|---|---|
| `multi_agent` (`collab`) | `spawn_agent`, `send_input`, `wait`, `close_agent`: Codex's own subagents | **off**, category agents |
| `memories` | Codex's memory store (`memories_1.sqlite`) and its tools | **off**, category artefacts |
| `apps` | ChatGPT connectors (Drive, etc.) exposed as tools | **off**, category artefacts, the same call as Claude's two connectors |
| `goals` | long-running goals (`goals_1.sqlite`; the adapter's goal extension) | **off**, category standing arrangements |
| `image_generation` | image generation | keep: not the app's remit |
| `web_search_request` / `web_search_cached` | `web_search` | keep: a work tool |
| `unified_exec`, `shell_snapshot`, `apply_patch_freeform`, `js_repl`, `undo` | shell, patching, REPL | keep: work tools |
| `request_user_input` / `default_mode_request_user_input` | its question tool | **keep and turn on in every mode**, as the escalation tool (R6) |

- **Lever**: `CODEX_CONFIG`, a JSON object the adapter parses at start
  (`JSON.parse(process.env.CODEX_CONFIG)`) and merges into every session's config. It is
  per process, additive, and writes nothing. **Decision**: a new `Lever.environmentJSON(variable:
  "CODEX_CONFIG", value:)` with value
  `{"features":{"multi_agent":false,"memories":false,"apps":false,"goals":false,"default_mode_request_user_input":true}}`.
  The policy's `removed` lists the tool names each switch removes, for the briefing.
- **To measure in the spike**: that each key is honoured. The adapter's error message says
  a bad `CODEX_CONFIG` fails the session open, which is loud, and good. Also measure that
  the tools are gone from the model's list, not merely refused. Any that remain become
  `residue`, and the briefing's residue line names them.
- **Rejected**:
  - `CODEX_HOME` pointing at an app-owned folder: it would move `auth.json` and sign the
    person out (D6, and Cursor's R7).
  - Editing `~/.codex/config.toml`: FR-016.
  - `-c key=value` on the `codex` command line: the adapter starts Codex, not the app, so
    there is no argument path.
- **The person's own MCP servers and profiles in `config.toml`**: left alone. Codex loads
  them with the app's. None of Alex's is known to duplicate the app.

## R6. Questions

The adapter handles Codex's `request_user_input` by calling `elicitation/create` (form)
when the client advertises form elicitation, which the app does, and falls back to empty
answers when it does not. **Decision**: `escalationTool: "request_user_input"`, kept in
the policy's `kept` list with the reason. `default_mode_request_user_input: true` in
`CODEX_CONFIG` lets it ask outside plan mode. **To measure in the spike**: a card appears
on the Mac and the phone, and an answer reaches Codex.

## R7. Usage, cost and limits

- The adapter sends `usage_update` with `used` and `size` (the context window) and no
  `cost`. It also tracks Codex's `rateLimits` (5-hour and weekly plan windows) in session
  state.
- **Decision**: the existing meter shows context use. Cost stays absent, never zero
  (FR-005).
- **To measure in the spike**: whether per-turn token counts arrive anywhere (the prompt
  result's `_meta`), and in what shape a plan-limit refusal reaches `session/prompt`, and
  whether it names a reset time. FR-011's sentence is built from that. If it arrives as an
  error with text, the existing "turn ended with an error" path already shows the text.

## R8. Modes and models

- The adapter's `AgentMode`s:
  - `read-only` ("Ask for approval": workspace-write, no network, approval on request);
  - `agent` (the default);
  - `agent-full-access` ("Full access": danger-full-access, approval never).

  `INITIAL_AGENT_MODE` picks the first. `session/set_mode` changes it. The model and
  reasoning effort come as config options. The existing mode and model menus read these
  generically, and the "helpers inherit the starter's mode, same runtime only" rule
  (548c5e1) covers D7.
- **To measure in the spike**: whether a call to the app's own MCP tools (`finish_turn`,
  `lease_resource`, …) raises a permission request in `agent` mode. If it does, try Codex's
  per-server `mcp_servers.<name>` approval setting through `CODEX_CONFIG` (FR-015). If that
  fails, record which tools ask, and keep the briefing from claiming otherwise.

## R9. Servers

- **Toolset**: the same manifest as the Mac's (one pin, D5), installed by 043's
  `ToolsetInstaller` into `~/.agents-server/tools/codex/<id>/`. The Linux Codex binaries
  are statically linked musl builds, so Codex itself adds no libc constraint. Node's glibc
  requirement, `canInstallClaude` today, still applies, and is renamed
  `canInstallToolset`.
- **Key**: an OpenAI API key (`sk-proj-…`, `sk-…`, never `sk-ant-…`), lent as
  `CODEX_API_KEY`. `OPENAI_API_KEY` is cleared when one is lent, so the lent one wins (it
  already takes precedence in the adapter; clearing makes it certain).
- **`NO_BROWSER=1`** in every server launch of Codex, so `chat-gpt` is never offered there
  (FR-020). `chat-gpt-device-code` remains, because it is the server's own sign-in and is
  written on the server by Codex. It is only reachable when the person marks the server
  "own sign-in only" (043), which is that mark's meaning.
- **To measure in the spike on agents-bare**: whether `CODEX_API_KEY` in the environment
  is enough for `session/new`, or whether `authenticate {methodId:"api-key"}` is needed. If
  it is needed, the launcher sets `DEFAULT_AUTH_REQUEST={"methodId":"api-key"}`, which the
  adapter reads for exactly this case.
- **Own sign-in on a server** (`ServerSignIn.exists("codex")`): `~/.codex/auth.json` on the
  server, or `CODEX_API_KEY` or `OPENAI_API_KEY` in its login environment.
- **Refused key**: the adapter's shape for a refused key is **to measure in the spike**, in
  order to extend `isAuthenticationFailure`, which today knows Claude's `errorKind`.
- **Checking a key on save**: `GET https://api.openai.com/v1/models` with
  `Authorization: Bearer`. 200 is **Works**, 401 is refused, and anything else is "could
  not check". It costs no tokens.

## R10. Claude-only points to generalise (shared with 046)

Every place 043 or 048 assumes the one toolset is Claude's:

- `Daemon/Sources/main.swift`: `Resources/toolsets/claude` becomes `Resources/toolsets`
  (every subfolder with a manifest).
- `Daemon.swift` / `RuntimeInstaller.toolset`: one `MacToolsetInstaller` becomes a map
  by runtime id. `recipe(for:)` looks up the runtime's own.
- `MacToolsetInstaller` and `ToolsetInstaller`'s shim is written as `bin/npx`; it becomes
  `bin/<runtime.executable>`, and the shim's comment becomes runtime-neutral.
- `ToolsetInstaller`: `serverFolder(runtimeID: "claude")` ×4 becomes
  `toolset.manifest.runtimeID`. `isInstalled`, `swap` and `removeOthers` take the runtime.
- `Host.swift` `canInstallClaude`; `ServerConnection`'s `Claude` state, `wantsClaude` and
  `installClaude` step; `HostSet.claudeToolset`: all become per-toolset.
- `DaemonCore+Credentials.swift`:
  - `lendableRuntimes = ["claude"]`;
  - `ServerSignIn.exists` (only `~/.claude/.credentials.json`);
  - `LentEnvironment.applied`, which clears Claude's two variables only;
  - `isAuthenticationFailure`.
- `CredentialKind`: prefixes and variables are Claude's. Each kind gains its `runtimeID`,
  and `allVariables` becomes per runtime.
- App: `ServerCredentials.runtimes = ["claude"]`, `Lending.swift` `record("claude")`,
  `AppModel.swift` `record("claude")`, `ServersSettingsView` `claudeLine`, and
  `AgentsSettingsView`'s Claude footer.

046's plan (Phase 2) lists the same set. Whichever lane lands first does it once. The
other merges it, and keeps only what the first lacked (046's plan predates 048, so it has
no Mac toolset map).

## R11. Moving the Mac toolset to a new pin

048 installs the Mac toolset only when it is missing. `RuntimeDiscovery.appToolset`
accepts any whole `current`, so a new pin in the app bundle is never installed. D5 needs
that fixed, and fixing it helps Claude too.

**Decision**: the design 046 planned for the same gap (its Phase 6, T035–T039), so the
two lanes build it once:
- discovery reports `outdated` when `current` does not resolve to the bundled toolset's id;
- the setup row offers **Update**, which runs the same install and moves `current`;
- each agent records the executable path it started from, and a toolset folder any agent
  still runs from is not removed until that agent ends.

Earlier draft, replaced: a silent install at start, with the swap made when no agent was
running. It was rejected to match 046, and because 048's rows already put installs in the
person's hands.

A running agent's process was started from the old folder's resolved path, so it keeps it.
**To confirm in Phase 4**: `SessionLauncher` launches through the resolved path, not
through `current`.

## Measured in the spike (2026-09-25, scratch root /tmp/run-codex, real ChatGPT account)

- **Install (T023)**: from the set-up sheet's **Install**, `runtimes/install codex` took
  **8 s** (04:03:18 to 04:03:26) and left a 540 MB toolset with only `codex-darwin-arm64`,
  and the row ticked with `…/tools/codex/current/bin/codex-acp`. Screenshots
  `walk/look/01–03`.
- **R3/US2**: an unsigned `agents/start` answered `-32007` "Codex needs signing in:
  Authentication required", with the three methods in `data`. `runtimes/accounts` then read
  `needsSignIn` with `canLogOut: true`.
- **R4**: `runtimes/authenticate {chat-gpt}` opened the browser from the adapter. Alex
  finished it, and it returned in **10 s** with `state: ready` and wrote
  `~/.codex/auth.json` (0600). No `~/.codex/config.toml` was created, before or after
  (SC-004 holds). The device-code fallback was not needed.
- **R2**: a real turn ("list your tools, write hello.txt, run ls, finish") listed all
  seventeen `mcp__agents__*` tools, wrote the file, ran `ls`, and ended through
  `finish_turn` with outcome `done`. It took 30 s.
- **R8**: the `finish_turn` call went through Codex's own "Guardian Review" auto-reviewer
  ("low-risk allow"), shown as a `think` tool call, and raised **no**
  `session/request_permission`. The app's tools do not wait for the person in `agent` mode.
  No `mcp_servers` approval key is needed.
- **R7**: `usage_update` gives `used`/`size` (15 002 of 258 400), and the turn's
  `usageRecorded` carries input, output and cached-read tokens. There is no cost figure
  (FR-005 holds with nothing new).
- **R6**: asked to use `request_user_input`, Codex raised a form elicitation ("Codex needs
  your input to continue.") with a choice field (Red / Blue / None of the above) and a note
  field. The agent went to `waitingOnUser`. Answering `{"colour":"Blue"}` over
  `elicitations/answer` resumed it, and it wrote `blue` and finished.
- **R5, revised**: the `CODEX_CONFIG` switches do apply. Turning off `shell_tool`,
  `unified_exec` and `code_mode_host` in a probe emptied the shell tools. But the
  `collaboration.*` tools (`spawn_agent`, `send_message`, `followup_task`,
  `interrupt_agent`, `list_agents`, `wait_agent`) stay with `multi_agent` and
  `multi_agent_v2` both off: the model's catalog entry names them. They are therefore
  **residue**. `sleep_tool` takes `clock.sleep`. `codex features list` (0.156.1) is the
  authoritative list of switches. Final value:
  `{"features":{"apps":false,"default_mode_request_user_input":true,"goals":false,"in_app_local_automation":false,"memories":false,"multi_agent":false,"sleep_tool":false}}`.
  `scripts/runtime-tools.sh codex` then reports 5 of 5 removed, the kept tool present, the
  6 residue named, and 0 unexplained.

## Measured on agents-bare (2026-09-25, T008): a server and an OpenAI key

The pinned toolset was installed by hand into `/tmp/codex-spike`: Node linux-arm64 checked
against the manifest's SHA-256, then `npm ci` of the lock in **4.2 s**, which pulled only
`codex-linux-arm64`. ACP was then driven over ssh from this Mac, with the key sent on stdin
into the adapter's environment and never on a command line.

- **`NO_BROWSER=1`**: `authMethods` is `api-key`, `chat-gpt-device-code`. There is no
  `chat-gpt` (FR-020).
- **Key in the environment alone**: `session/new` gives `-32000` "Authentication required".
  **With `DEFAULT_AUTH_REQUEST={"methodId":"api-key"}`** the session opens.
- **But the adapter's api-key sign-in saves the key**: it writes
  `~/.codex/auth.json` = `{"auth_mode":"apikey","OPENAI_API_KEY":"sk-…"}` (0600), and later runs
  reuse it, even with a different key in `CODEX_API_KEY`. That breaks FR-019. The file was
  deleted from the box straight away.
- `CODEX_CONFIG={"cli_auth_credentials_store":"ephemeral"}` does **not** help: it is thread
  config, and the file is still written.
- **`CODEX_HOME=<app-owned folder>` whose `config.toml` says
  `cli_auth_credentials_store = "ephemeral"`** does: no `auth.json` is written, and a search of
  that home for the key (its SQLite stores included) finds nothing. The session opens and
  reaches OpenAI.
- **Decision (servers, a key lent)**: start Codex with `CODEX_HOME=<server root>/runtimes/codex-home`
  (0700; the app writes only its `config.toml`), `DEFAULT_AUTH_REQUEST={"methodId":"api-key"}`,
  `CODEX_API_KEY` = the lent key with `OPENAI_API_KEY` cleared, and `NO_BROWSER=1`. When the
  server is "own sign-in only", none of that: Codex uses the server's own `~/.codex`.
  D6's rule against `CODEX_HOME` is about the person's home on their Mac; the app's own folder
  on a server signs nobody out.
- **Plan limit (R7)**: with the key's account out of credit, `session/prompt` answered
  `-32603` with `data: {"message":"Quota exceeded. Check your plan and billing details.",
  "codexErrorInfo":"usageLimitExceeded"}`. OpenAI's own answer for that key was
  `insufficient_quota` / `credit_balance_exhausted`. So a real server turn waits for Alex to
  add credit to that account. Everything short of the model's reply is proven.
- **Key check (FR-017)**: `GET https://api.openai.com/v1/models` answered 200 for that key even
  with no credit, so "Works" in Settings means the key is valid, not that it has credit. The
  quota ending says the rest.

## R12. Option 2: a server's Codex signed in through this Mac's ChatGPT sign-in (spike, 2026-09-25)

Alex asked for the Mac's ChatGPT sign-in to be usable on servers. A plain copy fails, because
Codex rotates the refresh token and two copies sign each other out. So this spike tried a
**relay**: the sign-in stays on the Mac, and the server's Codex sends its ChatGPT traffic
back to the Mac, which adds the Mac's current token. Alex allowed the Mac's `auth.json` to be
read for this. Files: `walk/relay-spike/` (`relay.py`, `run-trial.sh`, the relay's log, the
start of the trial log; there are no tokens in any of them).

**How it was wired**:
- On the box, Codex ran with its own `CODEX_HOME`, holding two files:
  - `auth.json`: a stand-in with `auth_mode: chatgpt`, JWTs whose signature is `standin`, the
    real account id (not secret), and `refresh_token: relay-standin-no-refresh`;
  - `config.toml`: `chatgpt_base_url = "https://127.0.0.1:18765/<secret>/backend-api/"`.
- `CODEX_CA_CERTIFICATE` pointed at a throwaway CA's public certificate.
- The relay on the Mac listened on 127.0.0.1:18765 with a server certificate from that CA,
  and was reached through `ssh -R 18765:127.0.0.1:18765`. It forwarded to
  `https://chatgpt.com`, replacing `Authorization` with the Mac's access token and setting
  `ChatGPT-Account-Id`.

**Measured**:
1. **It works.** The session opened, and a real turn ran `uname -a` on the box and returned
   `Linux 6cf224fd8030 6.8.0-117-generic … aarch64`, with usage (14 335 tokens,
   `gpt-6-astra`). The relay saw account and plugin checks, `ps/mcp`, analytics and
   `codex/responses`, all 200.
2. **Nothing of the real sign-in reached the box.** The last 24 characters of each real
   token (access, refresh, id) were searched for across `/tmp/codex-relay` and
   `/home/agents`, and none was found.
3. **Codex insists on HTTPS** ("workspace backend must use an HTTPS origin without
   credentials"). `CODEX_CA_CERTIFICATE` works, but the certificate must be a CA-signed
   server certificate (serverAuth, IP SAN). A self-signed certificate that is its own CA is
   refused by rustls without a word: nothing reached the relay.
4. **The secret path does not survive.** `chatgpt_base_url`'s path is kept for account and
   plugin calls, but workspace routing keeps only the origin, so `codex/responses` came to
   `https://127.0.0.1:18765/backend-api/codex/responses` without the secret. The spike let
   `/backend-api/` through. A real design needs another guard, because any process on the
   server that can reach that loopback port could use Alex's ChatGPT plan.
5. **WebSockets first**: Codex opens `wss://…/codex/responses` (101), then falls back to
   HTTPS POST when the relay does not carry the upgrade. It works either way; carrying the
   WebSocket would be the faster path.
6. **The Mac's token can go stale.** At the first try the Mac's access token had been
   invalidated ("token_invalidated", maybe when credits were bought). One Codex request on
   the Mac renewed it (`last_refresh` moved), and after that everything passed. The relay
   must deal with this: a 401 from chatgpt.com has to lead to a renewal, done by Codex on the
   Mac (so only one party ever rotates the refresh token), and then a retry.

**What a product version needs**:
- The relay built into the Mac's daemon, carried over the existing server link rather than a
  separate `ssh -R`.
- A guard on the server end: the server's agentsd listens on loopback and checks that the
  peer socket belongs to the same uid (`/proc/net/tcp` → inode → uid), or an equivalent.
- Its own CA, made per install and kept in the Mac's Keychain; only the public certificate
  goes to the server.
- Renewal on 401 through the Mac's Codex.
- The stand-in `auth.json` and `config.toml` written into the app-owned `CODEX_HOME` on the
  server. They hold no secret.
- A check that this use of a ChatGPT plan (one person, their own machines) is fine by
  OpenAI's terms.
