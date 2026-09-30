# Contract: what the app passes to every OpenCode process

Start: `<root>/tools/opencode/current/bin/opencode acp`, with the agent's folder as its cwd.

## Environment

| Variable | Mac | Server | Why |
|---|---|---|---|
| `OPENCODE_CONFIG_CONTENT` | the JSON below | same | D4: scoping, merged over the person's config |
| `OPENCODE_DISABLE_AUTOUPDATE` | `1` | `1` | D5 |
| `OPENCODE_DISABLE_SHARE` | `1` | `1` | FR-017 |
| `OPENCODE_AUTH_CONTENT` | removed | the lent sign-in, or removed on an "own sign-in only" server | D3, D7 |
| `OPENCODE_ENABLE_QUESTION_TOOL` | removed | removed | questions go through `ask_form` |
| provider keys (`ANTHROPIC_API_KEY`, …) | inherited, untouched | not added | D3 |

## `OPENCODE_CONFIG_CONTENT` (compact, sorted keys)

```json
{"autoupdate":false,
 "permission":{"bash":"ask","edit":"ask","webfetch":"ask"},
 "share":"disabled"}
```

A test holds this byte for byte. `tools` was here with `{"task": false}` until 2026-09-29; there is
no `tools` key at all now, and a runtime that is not in a policy's list is not taken away, so an
empty object would have been the same message written longer. The `permission` rules turn into
`session/request_permission`
with options `once` (allow_once), `always` (allow_always) and `reject` (reject_once). Under 061's
**Always approve**, the daemon answers `once` itself.

## Client capabilities sent in `initialize`

This adds `_meta: {"terminal-auth": true}` beside the existing `jetbrains.air` meta. OpenCode
then offers `opencode-login` with `_meta.terminal-auth = {command: "opencode", args: ["auth",
"login"]}`. The daemon replaces `command` with the shim's absolute path, because the runtime is
`usesAppCopyOnly` and the command equals its executable name.

## Failures mapped

| OpenCode says | Where | The app says |
|---|---|---|
| `-32000` with `providerId` | any | OpenCode needs signing in to <provider> (sheet) |
| `-32602 "model not found: …"` with `data.providerId` | `session/set_config_option` | OpenCode isn't signed in to <provider> (sheet) |
| `-32603 "…API key is invalid."`, `errorName: APIError` | `session/prompt` | <provider> refused the key (on a server: the Mac's sign-in, fix with `opencode auth login` on the Mac) |
| no reply to `initialize` within the start-up limit | start | OpenCode didn't answer; **Install** offered again |
