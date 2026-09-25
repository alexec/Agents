# Data Model: Zero-Setup Servers

## RuntimeCredential (Mac only)

| Field | Type | Notes |
|---|---|---|
| runtimeID | String | `claude` in this version (D3) |
| kind | `oauthToken` \| `apiKey` | From the prefix: `sk-ant-oat` / `sk-ant-api`. Anything else is refused at paste. |
| lastFour | String | For the mask: `sk-ant-oat…a3f9` |
| addedAt | Date | |
| lastWorked | Date? | Set by a good check (R9) or a good server session |
| lastRefused | Date? | Set by a refused check or `credentialRefused` |

- The secret itself is only in the Keychain: service `agents.runtime-credential.<root-id>`,
  account `runtimeID`. The rest is in `<root>/credentials.json`.
- Replace = write both; remove = delete both. Never logged, never `Codable` with the secret in it
  (the secret is a separate non-`Codable` wrapper whose `description` is the mask).
- Environment variable: `oauthToken` → `CLAUDE_CODE_OAUTH_TOKEN`; `apiKey` → `ANTHROPIC_API_KEY`.

## Toolset (bundle)

`App/Resources/toolsets/claude/manifest.json`:

| Field | Type | Notes |
|---|---|---|
| runtimeID | String | `claude` |
| node.version | String | e.g. `v24.21.0` |
| node.sha256 | `{x86_64, aarch64}` → String | Of the `.tar.xz` from nodejs.org |
| package | String | `@agentclientprotocol/claude-agent-acp` |
| packageVersion | String | e.g. `0.81.2` |
| entry | String | Path of the ACP entry inside the package, e.g. `dist/index.js` |
| minFreeBytes | Int64 | Refuse before download under this (≈ 400 MB) |

Beside it: `package.json`, `package-lock.json`. **Toolset id** = first 16 hex of SHA-256 over
manifest + lockfile bytes.

## InstalledTools (server, `~/.agents-server/tools/claude/`)

```text
tools/claude/
├── <toolset-id>/
│   ├── node/                 # unpacked Node
│   ├── lib/node_modules/…    # npm ci output
│   └── ok                    # written last; a toolset without it is never used
├── current -> <toolset-id>   # moved last
└── .part-<toolset-id>/       # during install; removed on any failure
```

States as the window sees them, per server per runtime (`ServerFacts.tools`):

```text
absent ──install──▶ installing ──ok──▶ ready ──app names newer──▶ outOfDate ──idle──▶ installing
   ▲                    │                                                                 
   └────── failed(reason) ◀─┘   (nothing left behind; Claude not offered on that server)
```

`ownInstall` is a separate state: no app toolset, but `npx` is on the login PATH (FR-005) — used
as is, nothing installed.

## ServerFacts (037) — additions

| Field | Type | Notes |
|---|---|---|
| libc | `glibc(version)` \| `musl` \| `unknown` | From `ldd --version` |
| downloader | `curl` \| `wget` \| nil | |
| toolsetID | String? | From `tools/claude/current` if its `ok` exists |
| hasNpx | Bool | Login-PATH `npx` exists (037 behaviour) |
| hasOwnClaudeSignIn | Bool | `~/.claude/.credentials.json` exists or `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` in the login env (names only, never values) |

## ServerHost (037) — additions

| Field | Type | Notes |
|---|---|---|
| ownSignInOnly | Bool | FR-014; default false. When true, nothing is ever lent to it. |
| knownProjects | [String] | Paths last seen on it, for FR-019 |

## HostProblem (037) — new cases

`noDownloader`, `noInternet(url)`, `unsupportedLibc(String)`, `toolsetChecksum`,
`toolsetInstallFailed(String)`, `diskFullForTools(needed: Int64, free: Int64)`. Each gets one
sentence in `HostProblem+Words.swift` (contracts/ssh.md § 4).

## Lend (server daemon memory only)

`[ConnectionID: [runtimeID: LentCredential]]` where `LentCredential` holds the secret and kind.
Created by `credentials/lend`, removed when the connection closes, never written, never in
`debugDescription`. Sessions launched with one carry `lentFrom: ConnectionID?` so a refusal can
be classified (R7).
