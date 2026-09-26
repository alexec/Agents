# Data model: 056

Nothing here is stored by the app. These are the shapes in memory and in the policy table.

## SignInRelay (policy, `AgentsKitCore`), generalised from 047

| Field | Codex (047, unchanged in meaning) | Claude (056) |
|---|---|---|
| `upstreamHost` | `chatgpt.com` | `api.anthropic.com` |
| `macSignIn` | `.file(".codex/auth.json")` | `.keychain(service: "Claude Code-credentials")` |
| `pointing` | `.home(homeVariable: "CODEX_HOME", configFile: "config.toml", signInFile: "auth.json", configTemplate: …)` | `.environment(["ANTHROPIC_BASE_URL": "https://127.0.0.1:{port}", "CLAUDE_CODE_OAUTH_TOKEN": "{standIn}"])` |
| `certificateVariable` | `CODEX_CA_CERTIFICATE` | `NODE_EXTRA_CA_CERTS` |
| `clearedVariables` | `OPENAI_API_KEY`, `CODEX_API_KEY` | `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` |
| `upstreamHeaders` | set `ChatGPT-Account-Id` from the sign-in | none beyond `Authorization` |
| `ownSignInVariables` | none (Codex has no server-side own check today) | `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, plus the file `~/.claude/.credentials.json` |

`Authorization`, `x-api-key` and hop-by-hop headers are always dropped from what the runtime
sent. `Authorization: Bearer <access>` is always set.

## MacSignInSource (protocol, `AgentsKit`)

- `isSignedIn: Bool`: signed in the way this relay lends (D3).
- `current() throws -> Token`: the access token and any upstream header values
  (`account` for Codex).
- `renew(after stale: Token) async throws -> Token`: returns a token different from
  `stale`, or throws `renewalRefused`. It never returns `stale` again.
- `standIn() throws -> String`: what the server's runtime starts with. It holds no secret.

### CodexFileSignIn

Today's `MacSignIn`, moved. It reads `auth.json` and renews by the OAuth exchange, writing
the file back (047).

### ClaudeKeychainSignIn

- **Reads**: `/usr/bin/security find-generic-password -s <service> -w` → JSON
  `claudeAiOauth { accessToken, expiresAt (ms), scopes }`. Signed in means the item parses
  and `scopes` contains `user:inference`.
- **Cache**: the last read, reused until `expiresAt − 60 s`. Dropped on any 401.
- **Renew**: one task in flight at a time, which every waiter awaits.
  1. Re-read. If the access token differs from `stale`, return it (the Mac's Claude
     renewed it).
  2. Else run the measured renewal command (research R6) through the Mac's `claude`, with
     a 30 s limit.
  3. Re-read. If it differs, return it. Otherwise `renewalRefused`.
- **Stand-in**: the constant `sk-ant-oat01-agents-relay-standin`.
- **Never**: writes, deletes or renews the Keychain item itself.

## Relay offers on a server (`DaemonCore`)

`relayOffers: [UUID: [String: RelayOffer]]`, by connection and then runtime. It was
`[UUID: RelayOffer]`, one per connection, which could only ever hold Codex. `relayGates`
stays keyed by socket path. Each runtime has its own forwarded socket (`relay-<runtime>.sock`),
so it has its own gate.

## Launch decision for Claude on a server

```
own sign-in only?            → [:]            (server's own; Claude's own ending if none)
relay offered for claude?    → relayed env    (R7)
server has own sign-in?      → [:]
else                         → throw signInWanted
```

## Removed

- `CredentialKind.oauthToken`, `CredentialKind.apiKey` and their prefixes, masks and wording.
- The `CredentialCheck` Claude path.
- `HostSet.claudeLine` (folded into `toolsetLine`).
- Claude's record in `credentials.json`, and the Keychain item
  `agents.runtime-credential.claude` (deleted on first start, once).
