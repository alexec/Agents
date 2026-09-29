# Research: OpenCode as a Runtime

**Probed**: 2026-09-28, OpenCode **1.18.33** (released 2026-09-28), `opencode-darwin-arm64.zip`
from GitHub, on a scratch home (`HOME` and every `XDG_*` under `/tmp/oc-spike/home`). The person's
own `~/.local/share/opencode` was not touched (its mtime is still 2026-09-12). The probe script is
`/tmp/oc-spike/probe.py`, a bare ACP client over stdio.

## R1. The release program

- The zip holds one file, `opencode` (145 MB, arm64). The zip's SHA-256 matches GitHub's `digest`
  in the release metadata (`24b12873…eb553`), so the manifest can carry GitHub's digests as they are.
- It is **ad-hoc signed** (`Signature=adhoc`, no team), not notarised. Downloaded by a program
  (no quarantine attribute), it runs with no Gatekeeper prompt. That is the spec's Gatekeeper
  edge case answered: the app must not set quarantine on it, and does not today.
- Linux assets are `.tar.gz`, not `.zip`: `opencode-linux-{x64,arm64}[-baseline][-musl].tar.gz`.

## R2. Signed out, it still works

With no `auth.json` and no provider key in the environment, `session/new` succeeds in 0.5–1.2 s
and offers 8 **OpenCode Zen** models that need no sign-in (`opencode/big-pickle`, the default,
and 7 `…-free` models). A prompt with the default model answered in 2.2 s. Usage came back with
`cost: {amount: 0, currency: "USD"}`.

So the spec's "No provider at all, but a free model" edge case is the normal first run: a fresh
install works without signing in. Story 3's "needs signing in" applies only to a model of a
provider that is not signed in, and such a model is not in the menu at all (R6).

## R3. Inline configuration is enough to scope the app's agents

`OPENCODE_CONFIG_CONTENT` is merged over the person's own config.

- `{"tools": {"task": false, "todowrite": false}}` becomes a `deny` permission rule for each, and
  the model no longer sees those tools (it listed `bash edit glob grep read skill webfetch
  websearch write` with them removed, and `… task todowrite …` without). The app can remove
  `task` and `todowrite` with **no residue**.
- `"permission": {"bash": "ask", "edit": "ask"}` makes OpenCode send
  `session/request_permission` with three options: `once` (allow once), always allow, reject.
- OpenCode's own default for the build agent is `"*": "allow"`: **it asks for nothing** except
  leaving the folder and a doom loop. The app must pass the permission rules that match the
  agent's permission mode (061), or an OpenCode agent will edit and run commands unasked.
- Environment switches also exist in the binary: `OPENCODE_DISABLE_AUTOUPDATE`,
  `OPENCODE_DISABLE_SHARE`, `OPENCODE_ENABLE_QUESTION_TOOL`, `OPENCODE_PERMISSION`,
  `OPENCODE_DISABLE_PROJECT_CONFIG`. The plan uses `autoupdate: false` and `share: "disabled"`
  in inline config and the two `DISABLE_` variables as well.
- `OPENCODE_ENABLE_QUESTION_TOOL=1` adds a `question` tool over ACP. The app leaves it off, as
  the spec says, so questions go through the app's `ask_form`.

## R4. OpenCode writes to its own home on first run

On a fresh home, OpenCode itself created `~/.config/opencode/opencode.jsonc` (just a `$schema`
line), `~/.cache/opencode` (models list, a `node_modules` for its built-in plugins) and 37 MB in
`~/.npm`. The app writes none of it, but FR-019/SC-005 as worded ("byte for byte") can only hold
for a home that already had OpenCode. The plan rewords SC-005 to what the app writes: nothing.

## R5. The app's tool server and resume

- `initialize` advertises `mcpCapabilities: {http, sse}`. A **stdio** server passed in
  `session/new` was still started, listed and called. Its tools reach the model as
  `agents_<tool>`, a prefix `AppTool.serverPrefixes` already strips.
- `loadSession: true`. A session made in one process loads in a new one (`session/load`
  returned the session's config options).

## R6. Models, modes and sign-in errors

- `configOptions` carries `model` (values `provider/model`, names `Provider/Model`) and `mode`
  (`build`, `plan`). There is no separate effort option for the Zen models, so effort appears
  only for models that have one.
- Choosing a model whose provider is not signed in fails at `session/set_config_option`:
  `-32602 "model not found: anthropic/claude-haiku-4-5"` with `data.providerId`. It never
  reaches a prompt.
- A refused key fails at `session/prompt`: `-32603 "Internal error: API key is invalid."` with
  `data.errorName: "APIError"`. The plan maps that to the sign-in failure sentence.
- `authMethods` has one method, `opencode-login`. With `clientCapabilities._meta["terminal-auth"]`
  set, it carries `_meta.terminal-auth = {command: "opencode", args: ["auth","login"]}`. The
  command is the bare name, so the app must swap in its own copy's full path, or it would run
  whatever `opencode` is on the PATH (the name trap).

## R7. Lending the Mac's sign-in to a server (Alex, 2026-09-28)

Alex chose **lend the Mac's sign-in** over D7's pasted key. The binary reads
`OPENCODE_AUTH_CONTENT`: the whole `auth.json` as JSON, read from the environment.

- With `OPENCODE_AUTH_CONTENT='{"anthropic":{"type":"api","key":"…"}}'` the model menu grew
  from 8 to 27 (Anthropic's models appeared). After the run, a search of the scratch home found
  the key nowhere: **it is used in memory, not written.**
- So a server run gets the Mac's `~/.local/share/opencode/auth.json` in that variable for that
  run, the way Claude's sign-in is lent (056). Nothing is written to the server's disk.
- Open for the plan: OAuth entries in `auth.json` (a ChatGPT or Copilot account) rotate their
  refresh token. If a server run refreshes one, the Mac's copy goes stale, as 047 found for
  Codex. The plan lends only entries that do not rotate (`type: "api"` and `wellknown`) until a
  rotating one is measured, and names the rest in the sheet.
