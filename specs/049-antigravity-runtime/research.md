# Research: Google Antigravity as a Runtime

Measured on this Mac (Apple silicon) on 2026-09-25 against `agy_acp_server` 1.2.1, with
`HOME` pointed at a scratch folder so that nothing of Alex's was touched. The probe scripts
live in `/tmp/agy-acp/` (not kept). Anything marked **to measure** needs a real turn, which
needs a Google sign-in or a real key, so it is Phase 0's spike.

## R1. Where ACP comes from

**Decision**: run Google's official Antigravity ACP server (`agy_acp_server`), as listed in the
ACP registry entry `antigravity-acp`.

**Rationale**:
- The `agy` CLI has no ACP mode (google-antigravity/antigravity-cli#31, open).
- The server is Google's own and needs no `agy`. Its own source says it is built for this: "an
  embedding IDE" relocating its home to "isolate this server's configuration and state from the
  user's other Antigravity surfaces".

**Alternatives considered**: the community adapters `agy-agent-acp`, `google-antigravity-acp`,
`antigravity-acp` (Bun) and `agy-acp`. They wrap the CLI's print mode or reuse its OAuth. They
are unofficial, they lack mid-turn permission, and the reuse of the CLI's OAuth is the exact
thing Google's terms name as a breach (R10).

## R2. Distribution

Measured, and taken from the registry's `antigravity-acp/agent.json` (version 1.2.1, licence
"proprietary"):

| Platform | Archive on `dl.google.com/agy-extensions/releases/` | Download | Command |
|---|---|---|---|
| darwin-aarch64 | `macos/agy-acp-server-1.2.1-darwin-arm64.zip` | 111,725,488 B | `./agy_acp_server.par` |
| darwin-x86_64 | `macos/agy-acp-server-1.2.1-darwin-x86_64.zip` | not fetched | `./agy_acp_server.par` |
| linux-x86_64 | `linux/agy-acp-server-1.2.1-linux-x86_64.zip` | 333,590,110 B | `./agy_acp_server.par --uid=` |
| linux-aarch64 | `linux/agy-acp-server-1.2.1-linux-arm64.zip` | 321,280,184 B | `./agy_acp_server.par --uid=` |

- The arm64 Mac zip has SHA-256
  `0fab9938812e6b32b3b543e65e4f3a0025ceef755413db13542d9a9b81ea803c`. It unpacks to 399 MB:
  `agy_acp_server.par` (277 MB, an arm64 Mach-O with Python embedded) and
  `localharness_external` (121 MB, the Go harness).
- Both binaries are signed "Developer ID Application: Google LLC (EQHXZ8M8AV)" with the hardened
  runtime.
- The registry publishes no checksums, so the app computes them when it pins a version
  (`scripts/update-toolset.sh`, archive mode) and carries them itself.
- What `--uid=` does on Linux is **to measure**. The registry passes it empty.

**Decision**: a new toolset shape, a **vendor archive**: per platform, a URL, a SHA-256, a size
and a command. No Node and no npm lock (data-model.md, contracts/toolset-archive.md).

## R3. The handshake

```
initialize → 6.4–7.8 s cold (two runs)
  agentCapabilities: loadSession ✓, promptCapabilities {image, audio, embeddedContext},
    mcpCapabilities {http, sse}, sessionCapabilities {list, resume}, auth {logout}
  authMethods: oauth-personal "Log in with Google", oauth-business "Log in with Gemini
    Enterprise", gemini-api-key, agent-platform
  agentInfo: antigravity-acp / "Google Antigravity" / 1.2.1
session/new, not signed in → -32000 "Authentication required", with data.message naming
  settings.json and each method's requirement
authenticate {methodId: gemini-api-key} → {} (and it persists auth.type, see R5)
session/new → +2.5 s. It returns modes (default, auto_edit, yolo), configOptions (model with
  14 Gemini 3.x choices, mode) and legacy models. It then sends available_commands_update with
  /plan and /logout.
session/list → the session, with cwd and title
```

Almost all of this is already generic in the app:
- `-32000` becomes `needsSignIn(authMethods:)`.
- `authenticate(methodID:)` and `logout` are in `ACPSession`.
- Resume, list, pictures, modes and models are read from the handshake.

**To measure**: whether `session/load` replays history as `session/update`s. The capability
says yes.

## R4. The app's tools (MCP)

The server advertises `mcpCapabilities {http, sse}`. Stdio MCP servers are ACP's baseline.
**To measure**: that the app's MCP server, passed in `session/new.mcpServers` as it is for every
runtime, reaches the model and its tools are callable.

The server also loads "global MCP configs" from `<home>/config/mcp_config.json`. With the app's
own home (R5) that file does not exist, so none of the person's servers load.

## R5. Where it keeps things, and D7

- Everything is rooted at `$GEMINI_HOME`, falling back to `~/.gemini`. That covers settings,
  conversations (a SQLite file each), "brain" artefacts, global hooks, skills and MCP config.
  The server also installs `antigravity/bin/webm_encoder` under it on first use.
- `authenticate` **writes** `auth.type` into `<home>/antigravity-acp/settings.json`.
- OAuth tokens go to the macOS Keychain when a default keychain answers a probe, and to a file
  under the home otherwise. `AGY_ACP_FORCE_FILE_STORAGE=1` forces the file. Linux always uses
  the file.

**Decision**: each agent's process gets `GEMINI_HOME=<root>/runtimes/antigravity/home` on the
Mac and `~/.agents-server/runtimes/antigravity/home` on a server.
- The person's `~/.gemini` is never read or written (FR-013, SC-004).
- Scratch roots are isolated from the real app's.
- Resume finds its conversations because the home is stable per root.
- The token stays in the Keychain, which is the server's choice and the safer one.

**Measured through the app's own launch (live test, 2026-09-25)**: `GEMINI_HOME` keeps
everything of the Python server's out of `~/.gemini`, but the Go harness it starts
(`localharness_external`) installs `webm_encoder` (12 MB) into `$HOME/.gemini/antigravity/bin/`
on the first turn, whatever `GEMINI_HOME` says. The only lever is `$HOME`, and moving it would
take the person's `.gitconfig`, `.ssh` and shell set-up away from `run_command`. **Decision**:
accept it as the one file-system exception, named in D7 and SC-004. It is Google's cache, and
the app never reads it. Worth reporting upstream.

**To measure**: the Keychain item's service name, and whether a scratch root's sign-in and the
real root's share it. If they do, that is acceptable (it is one person) and the plan records it.

**Alternatives**:
- Leaving the default `~/.gemini`. Rejected: it writes the person's files, and it loads their
  hooks, skills and MCP servers unscoped.
- Forcing file storage. Rejected: a token in a file is worse than one in the Keychain.

## R6. Signing in, and the key

- Environment-only selection has been removed. In the server's words: "AGY_ACP_ENABLE_OAUTH
  and a bare GEMINI_API_KEY no longer select an auth method; set `auth.type` in settings.json
  (or call `authenticate`). GEMINI_API_KEY is still used as the API key value when
  auth.type=gemini-api-key."
- The Agent Platform method uses `GOOGLE_API_KEY` / `GOOGLE_CLOUD_PROJECT` /
  `GOOGLE_CLOUD_LOCATION`.

**Decision**:
- **Key lent** (Settings holds the Gemini key, on the Mac or a server): the daemon sets
  `GEMINI_API_KEY` for that process only, and calls `authenticate {methodId: gemini-api-key}`
  after `initialize` and before `session/new`. This is data on the runtime (`lentKeyAuthMethod`)
  rather than a branch on its id. `GOOGLE_API_KEY` is cleared so Agent Platform can't be picked
  up by accident.
- **No key on the Mac**: nothing is lent. The first `session/new` answers `-32000`, and the
  existing sign-in sheet lists the four methods. **Log in with Google** calls
  `authenticate {methodId: oauth-personal}`. The server holds a local redirect listener
  (`WSGIRequestHandler`), so it presumably opens the browser itself. **To measure**: whether it
  opens the browser itself or returns a URL, and what arrives on the wire while it waits. If it
  opens nothing, the app opens the URL, as it does for Copilot.
- **No key on a server**: the app asks for the key in place (043). `oauth-*` is never offered
  there.
- **Removing the key later** leaves `auth.type=gemini-api-key` persisted in the app's home.
  **To measure**: that the next start without a key fails with a message the app can show as
  **Needs signing in**, and not a hang.

### R6a. Copying the Mac's Google sign-in to a server (D8, Alex 2026-09-25)

Read from the server's own code (`oauth/credential_store`, `OAuthCredentialManager`):
- The sign-in is one `google.oauth2` credentials blob (access token, refresh token, client id
  and secret), stored "as a single unit". It goes in the macOS Keychain under the server's own
  service name, or in a "secure file at `token_path`" under `GEMINI_HOME`.
  `AGY_ACP_FORCE_FILE_STORAGE=1` forces the file, and Linux always uses the file.
- There is no environment variable for it, so a server can only be given it as that file.

**Decision**:
- The Mac's Antigravity runs with `AGY_ACP_FORCE_FILE_STORAGE=1`. Its sign-in is then a 0700
  file in the app's own `GEMINI_HOME`, which the app can read without a Keychain prompt (reading
  another program's Keychain item would ask the person every time).
- On a server run, the daemon copies that file into the same relative path under the server's
  `GEMINI_HOME`, mode 0600, over the existing ssh channel, never through a log. It then calls
  `authenticate {oauth-personal}`, which with stored credentials should refresh rather than
  open a browser.
- The file is removed when the last Antigravity run on that server ends, and again at the next
  connect in case the app died first.
- No Mac sign-in: lend the Gemini key as before.

**Measured (T006, 2026-09-25, `agents-bare`, Debian 12 arm64 under Colima)**:
- **Where it goes**: `<GEMINI_HOME>/antigravity-acp/acp_token.json` for a personal Google
  sign-in, and `acp_business_token.json` beside it for Gemini Enterprise. The server's own
  docstring says so, and it is the same on the Mac and Linux. The file is one JSON blob, written
  0600 in a 0700 folder, atomically.
- **Headless with no token**: `authenticate {oauth-personal}` prints `Open the following link
  to authenticate the ACP server: https://accounts.google.com/…&redirect_uri=http://127.0.0.1:<random>/`
  on stderr and waits for ever. The redirect is to the server's own loopback, so the browser
  must be on that machine, which is why a server needs the Mac's copy.
- **Headless with a stored token Google won't accept** (a well-formed blob with a bogus refresh
  token): the same, printing the link and waiting for ever, with no error. It logs nothing that
  says whether it tried to refresh first.
- **Also found**: the server process outlives a dropped ssh session while it waits, and has to
  be killed.
- **Decision**:
  - The daemon never calls `authenticate {oauth-personal}` on a server without a limit.
  - It gives the call 20 s. If `Open the following link` appears on stderr first, it kills the
    process and says the Mac's sign-in needs renewing (US4 scenario 2b).
  - It never shows that link: it cannot be completed from anywhere but the server.
- **Measured with Alex's real Google sign-in (2026-09-25, 22:33)**:
  - **On the Mac**: the server was run with `GEMINI_HOME` in `/tmp` and
    `AGY_ACP_FORCE_FILE_STORAGE=1`, and sent `authenticate {oauth-personal}`. It logged
    `Credentials missing or invalid. Launching browser login flow...` and **opened the browser
    itself**. `authenticate` answered `{}` 6.7 s later, and a real turn replied "ready". The
    app has nothing to open.
  - **What it stored**: `antigravity-acp/acp_token.json`, 510 bytes, 0600, in a 0700 folder.
    The keys are `client_id`, `client_secret`, `project_id`, `refresh_token`, `scopes` and
    `token_uri`. No access token and no expiry are stored, so the file is the same after every
    refresh. Nothing went to the Keychain (file storage was honoured).
  - **Copied to `agents-bare`**: only that file went into a fresh `GEMINI_HOME`, 0600, over
    ssh stdin. `authenticate {oauth-personal}` answered `{}` in 0.9 s, with no link on stderr,
    `session/new` worked, and a real turn replied "Hi! How can I help you today?".
  - **No drift**: the file's SHA-256 was the same before and after the server's turn, and after
    a second Mac turn that followed it (`d6e6…8e20` throughout). The same refresh token works on
    both machines one after the other, and neither run rewrote it. So nothing needs copying
    back to the Mac. One sample, not a guarantee; the refused-copy path (2b) stays the answer
    if Google ever does rotate it.
  - The copy was removed from the box afterwards, and a search for `refresh_token` under its
    homes found nothing.

**Earlier questions, now answered or moved**:
- that `authenticate {oauth-personal}` with a stored file never opens a browser or blocks on
  a headless server;
- what the server says when the copied refresh token is refused;
- whether Google rotates the refresh token on refresh. If it does, copy the server's file back
  to the Mac at the end of a run when it is newer.

### R6b. The rest of the spike, measured on Alex's sign-in (2026-09-25, 22:40–22:58)

- **The app's tools arrive (R4).** A stdio MCP server passed in `session/new.mcpServers` (as
  the daemon passes the app's) reached the model. It called the tool with the right
  arguments. The call arrived with `_meta` naming the conversation and an artefacts folder
  under `GEMINI_HOME`.
- **But every MCP call asks permission first.** The server sends `session/request_permission`
  titled `<server>_<tool>` (for example `agents-probe_report_outcome`), with
  `_meta.mcp.tool`. The daemon's `autoAllowed` already answers the app's own
  turn-reporting, suggestion, file-pane and workflow tools, because it matches the name by
  suffix. The app's other tools (`lease_resource`, `wait_for_event`, `start_agent`…) would put a
  card in front of the person on every call. **Decision (built, T035a)**: the daemon auto-allows
  any call named with the app's server in front (`agents_…`, `mcp__agents__…`). `_meta` is not
  kept on stored tool calls, so the name is what is matched, and never a bare name.
- **The model's tool names (R7)** are not the `BuiltinTools` values:
  - With the deny list: `ask_question`, `call_mcp_tool`, `find_by_name`, `generate_image`,
    `grep_search`, `list_dir`, `list_resources`, `read_resource`, `read_url_content`,
    `replace_file_content`, `run_command`, `search_web`, `write_to_file`, `view_file`.
  - Without it, four more: `define_subagent`, `invoke_subagent`, `manage_subagents`,
    `send_message`.
  - So `disabledTools: ["start_subagent"]` takes away the whole subagent family, and the
    lever works.
  - There is no `finish` tool, so it does not compete with `finish_turn` and nothing more is
    removed.
  - There is no browser subagent, so there is no residue.
- **Questions (R7)**: `ask_question` arrived exactly as read from the code:
  - a `tool_call` with id `interaction_b72631a1` and the question as its title;
  - then `session/request_permission` whose options are the answers (`1` "Tea", `2`
    "Coffee", both `allow_once`);
  - the chosen answer reached the model, which replied "Tea".

  The app's permission card shows a titled question with two answer buttons. **Decision**:
  T034 changes nothing.
- **Trust (R7)**: in a fresh folder without `AGY_ACP_DISABLE_WORKSPACE_TRUST`, the only effect
  was the ordinary permission request for `run_command`. There was no trust prompt and no
  `trusted_workspaces.json`. The variable is kept (harmless, and like Gemini's D7), but it has
  no measured effect in 1.2.1.
- **Permission options**: `run_command` offers `allow_always` named "Allow Always (risky)",
  as well as the usual options.
- **Resume (R3)**: `session/load` of an ended conversation replays it as `session/update`s:
  the user's message, the `ask_question` call and the agent's answer. Its result carries no
  `sessionId`, which the protocol allows.
- **Sign-out (T002)**: `logout` → `{}`. The server logs `Cleared credential file at
  …/antigravity-acp/acp_token.json` and resets `settings.json` to `{}`. Conversations stay.
  It revokes nothing with Google (none logged): it only clears what is on disk.
- **Not measured**: a quota or rate-limit error (not provoked on the free tier), and usage
  reporting (no `usage_update` in any of these turns, so R11 stands).

> **Revised 2026-09-26 (Alex): Google sign-in only.** No key is lent to Antigravity (the Gemini
> key is Gemini's), so the "key lent" steps below are history. `GEMINI_API_KEY` and
> `GOOGLE_API_KEY` are always removed from the process, and the sign-in sheet hides
> `gemini-api-key` and `agent-platform`.

## R7. Tool policy

These are the server's built-in tools (the `BuiltinTools` enum): `list_directory`,
`search_directory`, `find_file`, `view_file`, `create_file`, `edit_file`, `run_command`,
`ask_question`, `start_subagent`, `generate_image`, `search_web`, `read_url_content`, `finish`.

- **Lever**: `_meta.agy.disabledTools` on `session/new`. It is re-sent on
  `session/load`/`resume` to override what was persisted. It is a deny list of canonical names,
  so it is exactly the existing `Lever.sessionMetaDenyList(path: ["agy", "disabledTools"])`.
  There's no new lever kind.
- **Removed**: `start_subagent` (`.agents`).
- **Kept**:
  - `ask_question`. It is the escalation tool: the server raises it as
    `session/request_permission` whose options are the answers, and it is never pre-gated.
  - `generate_image`, `search_web` and `read_url_content`. These don't overlap the app.
  - `finish`. It returns structured output and ends the conversation. **To measure** whether it
    competes with `finish_turn`. If it does, it is removed with `.escalation`.
- **Residue, in words**:
  - the `/plan` command, which "generates an implementation plan artifact" into the server's
    brain folder (`.artefacts`);
  - a browser subagent, whose settings appear in the strings (`browser_subagent`,
    `ANTIGRAVITY_BROWSER_TOOLS_ENABLED`) but which is not a built-in. **To measure** whether it
    is offered over ACP at all.
- **Workspace trust**: the server keeps `trusted_workspaces.json` and honours
  `AGY_ACP_DISABLE_WORKSPACE_TRUST=1`. **Decision**: set it per process, the equivalent of
  Gemini's `--skip-trust` (Alex, 046 D7). **To measure** what an untrusted folder does without
  it.
- **Questions**: `ask_question` arrives as a permission request whose options have custom names,
  all `allow_once` except ids `deny`/`dont_trust`/`block`, and it is single choice only. The
  app's permission card already shows option names. **To measure**: that the card reads as a
  question (the title is the question). If it doesn't, the card uses the `interaction_` prefix of
  the dummy tool call id as a question marker, and that prefix is recorded in the policy as data.

## R8. Start time

- `initialize` takes 6.4–7.8 s and `session/new` another 2.5 s: about 9–10 s to a session, cold,
  on an M-series Mac.
- The forum reports about 16 s on Windows, which isn't relevant here.
- SC-002 (at most Claude + 10 s) holds on this measurement.
- **Decision**: the start sheet shows **Starting Antigravity…**, which it already does for any
  runtime. The daemon's handshake limit must be at least 30 s. The plan checks the current value.

## R9. Failures seen

- **A refused key is not an error**. It arrives as an `agent_message_chunk` whose text is
  `Agent execution error: … "request failed (code 400): API key not valid. …"`, followed by
  `stopReason: end_turn`.
- **Decision**: the key is checked when it is saved (046's check against
  `generativelanguage.googleapis.com`), so a bad key rarely gets this far.
- For the rest, the runtime entry carries a `turnErrorPrefix` ("Agent execution error:") as data.
  A turn whose only message starts with it ends as **failed** with that sentence. If the sentence
  contains `API_KEY_INVALID` or "API key not valid", it is the refused-key failure with
  **Replace key** (043 FR-016).
- Quota and rate-limit text is **to measure**. It is expected to arrive the same way.

## R10. Terms

Antigravity's terms (antigravity.google/terms) say: "Using third party software, tools, or
services to access the Service (e.g. using OpenClaw with Antigravity OAuth) is a breach of this
Agreement."

**Decision (Alex, 2026-09-25)**: keep the Google-account sign-in, done only by Google's own
server. The app never reads, copies or lends the token. The sign-in sheet quotes that line
beside the Google methods and links to the terms. A key in Settings is always used first. The
server itself is only ever downloaded from Google onto the person's machine. The repo and the
app bundle carry its URL and checksum, never its bytes.

## R11. Usage and cost

No `usage_update` was seen, and the prompt result has no usage. Google's issue #1045 ("report
token usage and plan quota to ACP clients") is open. **Decision**: nothing is shown (FR-008),
and that's re-measured on a real turn.

## R12. Linux

- `--uid=` is passed, as the registry says.
- A TCMalloc crash on aarch64 is reported on Google's forum ("Antigravity ACP
  (agy_acp_server.par) TCMalloc failure on aarch64").
- **Measured (T006)**:
  - **arm64 works here.** Debian 12 arm64 under Colima on Apple silicon (4 KB pages): `initialize`
    in 0.8–3 s, a key sign-in, `session/new` and a refused-key turn, all like the Mac. The
    forum crash is probably specific to hosts with larger memory pages. **Decision**: arm64 is
    not marked `knownBroken`. A crash at start shows its stderr, and the plan keeps that path.
  - **x86_64 needs AVX.** Under Colima's x86 emulation it exits 132 at once with
    `FATAL ERROR: This binary was compiled with avx enabled, but this feature is not available on
    this processor`. So an x86_64 server without AVX can't run it. **Decision**: when a start
    exits with that line, the agent shows it as "this server's processor can't run Antigravity".
    A real x86_64 run still needs a real x86_64 box.
  - **Size**: 1.0 GB unpacked on Linux (the `.par` is 921 MB), from a 321–334 MB zip, so about
    1.35 GB at peak during install. `minFreeBytes` is now 2 GB.
  - **Unpacking**: a bare Debian has `curl` and `tar` but no `unzip`, `bsdtar` or `python3`, so the
    server can't unpack Google's zip itself. **Decision**: the Mac downloads the zip, checks it,
    unpacks it and sends it to the server as a gzipped tar over the existing ssh channel (about
    the same size as the zip). The server checks nothing it can't. The Mac's check against the
    pinned SHA-256 is the check. That replaces "curl, sha256sum, unzip" in
    contracts/toolset-archive.md for servers.
  - **`--uid=`**: an option of Google's own launcher. Left empty, it stops the launcher running
    the program as another user. It is kept as the registry gives it.
  - **Home on Linux**: `GEMINI_HOME` holds settings and conversations, and the harness again puts
    `webm_encoder` in `$HOME/.gemini/antigravity/bin/`, as on the Mac (R5).
- **Decision**: the manifest marks `linux-aarch64` as `knownBroken: true` until the spike shows
  otherwise. A server on that platform then says so and doesn't install (FR-020).
- **To measure**:
  - x86_64 on a bare server: the 334 MB download, the unpacked size (sets `minFreeBytes`), a
    turn with a lent key, and a leak check;
  - arm64 on the devbox, which is Colima on Apple silicon, so arm64 is the platform it can test
    directly.

## R13. Sharing 046's and 047's groundwork

The Codex lane (047) is implementing the following:
- `Runtime.usesAppCopyOnly`;
- every bundled toolset keyed by runtime;
- **Update** on an outdated toolset;
- keeping the folders of running agents;
- a runtime named in the installer's words.

046 and 047 both plan the per-runtime 043 generalisation: credential kinds by runtime, lending,
and the "own sign-in" check.

**Decision**: 049 builds on whichever of them has landed. It adds only:
1. the vendor-archive toolset shape, on the Mac and on servers;
2. `GEMINI_HOME` and the other per-process variables;
3. `lentKeyAuthMethod` and `turnErrorPrefix` on the runtime;
4. the Gemini key kind serving two runtimes. If 046 hasn't landed, 049 adds the kind itself.
