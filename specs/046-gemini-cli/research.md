# Research: Gemini CLI as a Fifth Runtime

Measured on 2026-09-25 against `@google/gemini-cli@0.61.0` (the npm `latest` that day), on
this Mac with Node v26.8.2. Gemini is not installed here and nobody is signed in, so
everything below that needs a live turn is marked **to measure in the Phase 0 spike** (T-spike
in tasks), which needs a Gemini API key from Alex.

The probe ran in a scratch home (`HOME=/tmp/gemini-probe`) so nothing reached `~/.gemini`.
npm's cache is not moved by `HOME` (it lives in `~/.npm`), so the package itself landed in
`~/.npm/_npx/609056658260efd2/`. That is the same cache Claude's adapter uses, and is not
Gemini's.

## R1. Package, command and flag

- **Decision (revised 2026-09-25)**: the start-up installer (another lane) installs
  `@google/gemini-cli@0.61.0` and a pinned Node on the Mac; the app starts
  `<installed node> <installed package>/bundle/gemini.js --acp`. id `gemini`, name `Gemini`.
  Alex first chose npx, then moved Gemini to the installer, as he did for Codex (047). The
  measurements below were taken through npx and hold for the installed package: same bundle,
  same flag.
- **Measured**: the package's only bin is `gemini` (`bundle/gemini.js`); `engines.node` is
  `>=20`; unpacked size 98 MB (95 MB on disk once fetched, ~100 MB with its three
  dependencies `@github`, `@lydell`, `node-pty`). `--help` lists `--acp` ("Starts the agent in
  ACP mode") and `--experimental-acp` ("deprecated, use --acp instead").
- **Fetch cost**: `npx -y @google/gemini-cli@0.61.0 --help` from an empty cache took **5.7 s**
  on this Mac and network, so the installer's Gemini entry is a small one beside Node's.
- **Pinned (D5)**: one version per app version, the same on the Mac and servers, moved by
  `scripts/update-gemini-toolset.sh`. The ACP surface moves between releases (R3–R6 are
  version-specific; `--experimental-acp` is already deprecated).
- **One manifest for both places**: `App/Resources/toolsets/gemini/manifest.json` (043's
  format) carries Node's checksums for `darwin-arm64` and `darwin-x64` as well as the two Linux
  ones, so the installer and 043's server install read the same pin. Proposed to the installer
  lane as its entry format; if it chooses another, the Gemini entry is written in that.
- **Alternatives**: npx through the person's Node (Alex's first answer, replaced); `@latest`
  (rejected, above); `--experimental-acp` (deprecated); a `gemini` on the PATH (never used, R11).

## R2. Handshake: what Gemini says about itself

`initialize` with protocol 1 returned, unsigned:

```json
{"protocolVersion":1,
 "authMethods":[
   {"id":"oauth-personal","name":"Log in with Google","description":"Log in with your Google account"},
   {"id":"gemini-api-key","name":"Gemini API key","description":"Use an API key with Gemini Developer API","_meta":{"api-key":{"provider":"google"}}},
   {"id":"vertex-ai","name":"Vertex AI","description":"Use an API key with Vertex AI GenAI API"},
   {"id":"gateway","name":"AI API Gateway","description":"Use a custom AI API Gateway","_meta":{"gateway":{"protocol":"google","restartRequired":"false"}}}],
 "agentInfo":{"name":"gemini-cli","title":"Gemini CLI","version":"0.61.0"},
 "agentCapabilities":{"loadSession":true,
   "promptCapabilities":{"image":true,"audio":true,"embeddedContext":true},
   "mcpCapabilities":{"http":true,"sse":true}}}
```

- **Resume (US1 #5)**: `loadSession: true`, and the agent implements `session/load`,
  `session/list` and `unstable_resumeSession`. Resume works through the existing path; no
  "starts afresh" wording is needed.
- **Pictures**: `image: true`. The existing capability check sends pictures as pictures.
- **Sign-out (US2 #4)**: no `logout` method anywhere in the ACP agent, and no
  `supportsLogout`. The sheet shows no sign-out button, as for Cursor. Nothing to build.
- **Sign-in methods**: four, none with a terminal command. `RuntimeAccount.preferredMethod`
  picks the first one without a terminal, which is `oauth-personal`. See R4 for what each does.
- **MCP**: `mcpCapabilities.http` is true. **To confirm in the spike** that the app's MCP
  server, passed in `session/new` `mcpServers` the way it is for the other four, reaches
  the model. The app's other runtimes already take it this way, so no new transport.

## R3. Not signed in

`session/new` unsigned returned `{"code":-32000,"message":"Gemini API key is missing or not
configured."}`. `-32000` is ACP's `authRequired` (the bundle's `RequestError.authRequired`
builds exactly that code), which the daemon already turns into `needsSignIn` for the other
runtimes. So FR-007 needs no new detection: the existing refusal path fires, and the message
Gemini sends is a sentence already.

stderr, same run: "Skipping project agents due to untrusted folder", "Project hooks disabled
because the folder is not trusted", "Ripgrep is not available. Falling back to GrepTool."
Nothing fatal.

- **Trusted folders**: Gemini keeps `~/.gemini/trustedFolders.json` and, for an untrusted
  folder, skips that project's own agents, hooks and settings. `--skip-trust` trusts the
  folder for one session without writing that file. **Decision**: do not pass it. Whether a
  project's `.gemini/` hooks run inside the app's agents is Gemini's call and the person's,
  exactly as it would be in their terminal; passing `--skip-trust` would quietly run a cloned
  repo's hooks. **To measure in the spike**: that an untrusted folder does not stop a turn.
- **What Gemini writes in its home**: the probe's `.gemini/` gained `installation_id`,
  `projects.json`, `history/` and `tmp/`. That is Gemini writing its own state, which it does
  from a terminal too. FR-013 is about the app: the app writes none of these. SC-004's check
  therefore compares `~/.gemini/settings.json` (and `trustedFolders.json`), not the whole
  folder.

## R4. Signing in

- **Mac (D3)**: Gemini reads its own sign-in: `~/.gemini/oauth_creds.json` from a Google
  sign-in, or `GEMINI_API_KEY` / `GOOGLE_API_KEY` in the environment, plus the auth type chosen
  in `~/.gemini/settings.json`. The daemon already starts runtimes with the login shell's
  environment (`LoginShellPath.environment()`), so a key in the person's profile reaches it.
- **ACP `authenticate`**: the existing sign-in sheet lists the four methods and calls
  `authenticate` with the chosen id. **To measure in the spike**: what `oauth-personal` does
  over ACP (it is expected to open a browser from the agent process, as it does in a
  terminal); what `gemini-api-key` does with no key in the environment (expected: a refusal
  naming `GEMINI_API_KEY`). If `oauth-personal` cannot complete over ACP, the sheet falls back
  to the Copilot pattern: hand over `npx -y @google/gemini-cli@<pin>` with **Open Terminal**
  and **Copy**, where the person signs in once and Gemini keeps it.
- **Servers (D4)**: a Gemini API key, lent as `GEMINI_API_KEY` for that run, the same as 043's
  `ANTHROPIC_API_KEY`. `GOOGLE_API_KEY` is taken out of the environment when a key is lent so
  the lent one wins (Gemini prefers `GOOGLE_API_KEY` when both are set). Gemini also needs its
  auth type to be the API key; **to measure in the spike** whether a key in the environment with
  no `settings.json` is enough (expected, from the `session/new` message above), or whether the
  lend must also call `authenticate` with `gemini-api-key`.
- **Key shape**: AI Studio keys start `AIza` and are 39 characters. `CredentialKind` today is
  Claude's prefixes only; it gains a `geminiAPIKey` kind recognised by that prefix.
- **Checking a key on save (FR-014)**: `GET
  https://generativelanguage.googleapis.com/v1beta/models` with header `x-goog-api-key`. 200 is
  **Works**; 400 with `API_KEY_INVALID` is refused; anything else is "could not check". It is
  the same shape as 043's Anthropic check and costs no tokens.

## R5. Tools, and taking some away

Tool names from the 0.61.0 bundle's `*_TOOL_NAME` constants:

| Gemini tool | What it is | Decision |
|---|---|---|
| `invoke_agent` | starts a subagent (`codebase_investigator`, `cli_help`, `generalist`) | **remove**, category agents |
| `tracker_create_task`, `tracker_update_task`, `tracker_get_task`, `tracker_list_tasks`, `tracker_add_dependency`, `tracker_visualize` | a task queue kept by Gemini | **remove**, category standing arrangements (Copilot's task queue was the same call) |
| `ask_user` | its question tool | already gone in ACP mode (R6) |
| `enter_plan_mode`, `exit_plan_mode` | plan mode | keep: a mode, which the app shows from `modes` |
| `write_todos` | a to-do list inside the turn | keep, as Claude keeps its to-do tool |
| `complete_task` | ends a subagent's run | keep: only exists inside a subagent, which is removed |
| `update_topic`, `take_snapshot`, `get_internal_docs`, `activate_skill` | session title, checkpoint, its own docs, its skills | keep: none duplicates the app's remit |
| `read_file`, `read_many_files`, `write_file`, `replace`, `list_directory`, `glob`, `grep_search`, `run_shell_command`, `web_fetch`, `google_web_search`, `list_background_processes`, `read_background_output`, `list_mcp_resources`, `read_mcp_resource` | work tools | keep |

There is no `save_memory` tool in 0.61.0: the prompt says "There is no `save_memory` tool"
and memory is plain Markdown edits.

- **Lever**: Gemini's policy engine. `--policy <file>` loads "additional policy files" (TOML,
  `toolName` string or array, `decision = "deny"`, optional `denyMessage`). It is per launch,
  additive to the person's own policies, and needs a path the app writes: the same shape as
  Grok's `GROK_CONFIG_PATH` overlay, except pointed at by an argument, not a variable.
- **Decision**: extend `EnvironmentFile` so a file can be named by a launch argument
  (`argument: "--policy"`) instead of a variable, and give Gemini a `.launchArguments` lever
  with no flag of its own, only that file. The file is `<root>/runtimes/gemini-policy.toml`,
  rebuilt each launch from `ToolPolicyCatalog.gemini.removed`, with a `denyMessage` built
  from each category's `instead` sentence so a refused call tells the model what to use.
- **Open, to measure in the spike**: whether a deny rule with no `argsPattern` also takes the
  tool out of the model's declarations (Gemini's docs say it does) or only refuses the call.
  Either satisfies FR-011, since a refused call names the app's tool; the briefing's removed
  line is true in both cases. If it only refuses, record that in the policy's comment.
- **Rejected**: `GEMINI_CLI_SYSTEM_SETTINGS_PATH` pointing at an app-owned `settings.json` with
  `tools.exclude`. It works per process and touches nothing of the person's, but system
  settings *override* user settings key by key, so the person's own `tools.exclude` and
  `mcpServers` would be replaced, not added to. The policy file only adds.
- **Rejected**: `--allowed-tools` (deprecated, and an allow list, which R2 of 015 rejected for
  Claude for the same reason).
- **The person's MCP servers**: left alone. Gemini loads `mcpServers` from
  `~/.gemini/settings.json` as well as those in `session/new`. None of Alex's are known to
  duplicate the app today; if one does, `--allowed-mcp-server-names` is the lever, as
  `--disable-mcp-server` is for Copilot. Not used in this version.

## R6. Questions

`gemini.js` (the ACP entry) builds its exclude list with:

```js
const isAcpMode = !!argv.acp || !!argv.experimentalAcp;
if (!interactive || isAcpMode) { extraExcludes.push(ASK_USER_TOOL_NAME); }
```

So in ACP mode Gemini has no question tool at all, and nothing reaches the client as an
elicitation (the ACP code has no elicitation path). **Decision**: `escalationTool: nil`, and
a mid-turn question arrives as the turn's text, which the app's outcome report turns into
**Waiting on your answer**, exactly as for Grok. FR-012's fallback branch, taken on
measurement, not by default.

## R7. Usage and cost

- The ACP code sends no `usage_update` session update.
- `session/prompt` returns `_meta.quota`:
  `{"token_count":{"input_tokens":N,"output_tokens":N},"model_usage":[{"model":"…","token_count":{…}}]}`
  on every ending, including errors.
- No cost figure anywhere.
- **Decision**: `ACP.PromptResult` gains an optional `_meta.quota.token_count` read. When
  present, the turn's tokens show as for other runtimes; cost stays absent (FR-005: nothing
  rather than zero). `model_usage` names the model that actually answered, which is how the
  **free-tier fallback** edge case is shown truthfully: when the answering model differs from
  the session's `currentModelId`, the agent's model line follows the one that answered.
- Context-window size is not reported; the meter's "used of size" stays off for Gemini, as for
  runtimes with no `usage_update` today.

## R8. Modes and models

`session/new` returns `modes` (`default`, `auto_edit`, `yolo`, `plan` when plan is enabled)
and `models` (`availableModels`, `currentModelId`), and implements `session/set_mode` and
`unstable_setSessionModel`. The app's existing mode and model menus read these generically.
Nothing Gemini-specific. The permission-mode mapping 047 and the helpers work (548c5e1) use,
"same runtime only", holds: a Gemini starter's `yolo` is only handed to Gemini helpers.

## R9. Quota and rate limits

Gemini surfaces `RESOURCE_EXHAUSTED` from the API as an error event. **To measure in the
spike** (with a free-tier key, by asking for a large model repeatedly) what shape reaches ACP:
an error on `session/prompt`, or `stopReason: "refusal"` with text. Either way the app's
existing "turn ended with an error" path shows the message; the task is to check the message
is a sentence and not a stack.

## R10. Servers

- **Toolset**: a second manifest at `App/Resources/toolsets/gemini/`: the same Node (v24.21.0,
  already pinned for Claude, and `>=20` satisfies Gemini), `package: "@google/gemini-cli"`,
  `packageVersion: "0.61.0"`, `entry: "bundle/gemini.js"`, and a lock made by
  `scripts/update-gemini-toolset.sh` (a copy of `update-claude-toolset.sh` with the package
  swapped). `minFreeBytes` ~ 400 MB (Node ~ 180 MB unpacked + Gemini ~ 100 MB + slack).
- **`node-pty`**: an optional native dependency with prebuilt binaries for linux-x64 and
  linux-arm64 on glibc. **To measure in the spike on agents-bare**: that `npm ci` succeeds
  without a compiler (expected: prebuilt used, or optional dependency skipped), and that
  `run_shell_command` still works if it was skipped (Gemini falls back to `child_process`).
- **Each toolset whole and separate** (`~/.agents-server/tools/gemini/<id>/`), including its
  own Node. Sharing Node between toolsets would save ~ 180 MB but couple two runtimes' updates;
  043's "replaced as a whole" rule is simpler to keep true per runtime.
- **Generalising 043**: every Claude-only point found in the code, each of which becomes a
  per-runtime lookup:
  - `DaemonCore.lendableRuntimes = ["claude"]` and `ServerSignIn.exists` (`~/.claude/.credentials.json`)
  - `LentEnvironment.applied` clears `CredentialKind.allVariables` (Claude's two)
  - `App/Sources/Settings/ServerCredentials.swift` `runtimes = ["claude"]`
  - `App/Sources/Hosts/Lending.swift` `credentials.record("claude")`
  - `App/Sources/AppModel.swift:998`, `ServersSettingsView.swift:80` `record("claude")`, `claudeLine`
  - `App/Sources/Hosts/HostSet.swift:442` the bundled `toolsets/claude` folder
  - `ToolsetInstaller` scripts hard-code `serverFolder(runtimeID: "claude")`;
    `ServerFacts.canInstallClaude`
- **Overlap with 047 (Codex)**, planned in another lane: it needs the same generalisation.
  Whichever lands first does it once, as its own phase (Phase 2 here), and the other merges
  it. Nothing in this plan depends on 047's start-up installer, because Gemini on the Mac is
  npx (D1).

## R11. Nothing on the person's PATH changes

`gemini` is never looked up on the PATH, so a person's own `npm i -g @google/gemini-cli` is
untouched and unused (as for Claude and its adapter). A person who wants a different version
uses it from their terminal. Recorded because Cursor/Grok taught that name collisions on PATH
cost a day.
