# Phase 0 spike, 2026-09-25

On `agents-bare` (Debian bookworm, aarch64, glibc 2.36; ssh, curl, xz, git only), by hand over
ssh with the pinned toolset `dcc7e847c9890e9d` (Node v24.21.0, claude-agent-acp 0.81.2).

## T006 — install with install scripts off: works

contracts/ssh.md § 2 run as written, except that `npm ci --prefix "$P/lib"` needs
`package.json` and `package-lock.json` *in* `lib/` (fixed in the contract).

- Download, checksum, unpack, `npm ci --ignore-scripts --omit=dev`: **14 s** on this Mac's network.
- npm took only `claude-agent-sdk-linux-arm64` (not musl, not other platforms).
- Size: **484 MB** — Node 204 MB, the SDK's native Claude binary 223 MB, the rest ~20 MB. So
  `minFreeBytes` goes from 400 MB to **800 MB** (download + unpack + npm cache at the peak).
- With scripts ignored the adapter starts, `initialize` and `session/new` answer, and the SDK
  initialises its native binary (`phase=sdk-initialize … 420 ms`). **R2 holds.**
- macOS `tar` adds `LIBARCHIVE.xattr.com.apple.provenance` headers that GNU tar warns about;
  stream with `COPYFILE_DISABLE=1 tar --no-xattrs` (or `--no-mac-metadata`).

## T009 — what a bad sign-in looks like over ACP

| Sign-in | `session/prompt` answer | Time |
|---|---|---|
| none | `{"code":-32000,"message":"Authentication required"}` | at once |
| `CLAUDE_CODE_OAUTH_TOKEN` made up | `{"code":-32603,"message":"Internal error: Failed to authenticate. API Error: 401 OAuth access token is invalid.","data":{"errorKind":"authentication_failed"}}`, after an `agent_message_chunk` with the same sentence | ~2 s |
| `ANTHROPIC_API_KEY` made up | same, "401 API key is invalid.", `errorKind: authentication_failed` | **~3 min** (the SDK retries first) |

Also: the adapter sends `_auth/status_update {"authStatus":{"kind":"api_key","detail":"ANTHROPIC_API_KEY"}}`
when it picks up the API key variable.

**R7's matcher is `error.data.errorKind == "authentication_failed"`** (text is a fallback only).
`-32000 Authentication required` means *no* sign-in, which is `credentialWanted`, not refused.
The API-key case needs the check at save time (R9) to be the early warning; the refusal still
arrives, late.

## T010 — the check endpoint (partly)

`GET https://api.anthropic.com/v1/models`, `anthropic-version: 2023-06-01`:

- `x-api-key: <made-up>` → 401 `authentication_error` "API key is invalid."
- `Authorization: Bearer <made-up oat>` (with or without `anthropic-beta: oauth-2025-04-20`) →
  401 "OAuth access token is invalid."

So the endpoint recognises both kinds and refuses a bad one; **a 200 for a real subscription token
is not yet seen** — that needs Alex's token.

## With a real token (2026-09-25, through the window)

- T007: a real turn on `agents-bare` through the forwarded Linux `agentsd`, token lent by the window: answered, file written, 4 s from Send (walk/README.md #11).
- T008: env wins over `claude login` (a made-up env token was refused on the signed-in devbox).
- T010: `/v1/models` answers 200 for a real subscription token with `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`.

## Was waiting on a real token

- T007: one turn on `agents-bare` with the token in the environment only.
- T008: on `agents-devbox` (signed in with `claude login`), a *different* token in the environment — which wins.
- T010: a 200 from `/v1/models` with a real subscription token.
