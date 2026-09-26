# Data Model: Google Antigravity as a Runtime

Only what changes or is new. Field names are indicative; the contracts fix the wire shapes.

## Runtime (catalog entry `antigravity`)

> Built (2026-09-25): `launchEnvironment`, `lentKeyAuthMethod`, `turnErrorPrefix` and
> `signInNotice` live in `RuntimeLaunchCatalog` (`Core/Runtimes/RuntimeLaunch.swift`), keyed by
> runtime id, plus `lentKeyVariable` and `refusedKeyMarkers`. They are not on `Runtime`, which
> travels to the phone. A failed turn ends with the new `EndedReason.runtimeError`, or with
> `.signInRefused` for a refused key.

| Field | Value | Notes |
|---|---|---|
| `id` | `antigravity` | |
| `name` | `Antigravity` | |
| `executable` | `agy_acp_server` | the shim in the toolset's `bin/` |
| `arguments` | `[]` on the Mac; `["--uid="]` on Linux, from the manifest's platform entry | |
| `install` | `.toolset(runtimeID: "antigravity")` | archive shape |
| `installPage` | `https://antigravity.google/docs/ide/extensions` | registry's `website` |
| `usesAppCopyOnly` | `true` | (047's field) |
| `launchEnvironment` **new** | `GEMINI_HOME=<root>/runtimes/antigravity/home`, `AGY_ACP_DISABLE_WORKSPACE_TRUST=1`, `GOOGLE_API_KEY=` (unset) | `<root>` substituted per daemon; the server's root on Linux |
| `lentKeyAuthMethod` **new** | `gemini-api-key` | when a key is lent: set its variable, then `authenticate` with this id before `session/new` |
| `turnErrorPrefix` **new** | `Agent execution error:` | a turn whose agent text starts with it ends as failed |
| `signInNotice` **new** | quoted terms line + `https://antigravity.google/terms`, shown beside methods `oauth-personal`, `oauth-business` | |

Other runtimes leave the four new fields empty; nothing about them changes.

## Toolset, archive shape

```
ArchiveManifest
  runtimeID: "antigravity"
  kind: "archive"
  version: "1.2.1"                       # the vendor's version, shown on the row
  source: "acp-registry:antigravity-acp" # where update-toolset.sh read it from
  minFreeBytes: Int64                     # per the unpacked size + margin (Mac 399 MB; Linux to measure)
  platforms: { <platform>: Platform }     # darwin-aarch64, darwin-x86_64, linux-x86_64, linux-aarch64
Platform
  url: URL                 # dl.google.com only
  sha256: String           # computed by update-toolset.sh; the registry has none
  size: Int64              # bytes, for progress and the row's note
  command: String          # "agy_acp_server.par", relative to the unpacked folder
  arguments: [String]      # ["--uid="] on Linux
  knownBroken: String?     # reason, e.g. linux-aarch64 TCMalloc crash; absent = fine
```

- **id**: first 16 hex of SHA-256 of `manifest.json`'s bytes (no lock file).
- **Installed folder**: `<id>/` holding the unzipped files, `bin/agy_acp_server` (shim that
  `exec`s the command with its arguments and `"$@"`), and `ok` written last. `current` → `<id>`.
- **States** (048's): not installed → installing(bytes, total) → installed | installFailed(reason);
  installed + bundle id ≠ current id → outdated (**Update**); a folder an agent runs from is kept
  until that agent ends.

## Tool policy `antigravity`

| | |
|---|---|
| lever | `sessionMetaDenyList(path: ["agy", "disabledTools"])` |
| removed | `start_subagent` (.agents) |
| kept | `ask_question` (escalation), `generate_image`, `search_web`, `read_url_content`, `finish` (pending spike, R7) |
| residue | `/plan` command → plan artefact in the server's brain folder (.artefacts); browser subagent if the spike finds it offered |
| escalationTool | `ask_question` |

## Credential

046's Gemini API key kind (`AIza…`, `AQ.…`), one Keychain item. **Lent to**: `gemini`,
`antigravity`. Lent as `GEMINI_API_KEY` for that process only. For Antigravity, lending also
means `authenticate {gemini-api-key}` (above). Never lent to any other runtime; never on a
server's disk.

## Sign-in state (per daemon root)

Held by the server under `GEMINI_HOME`, not by the app: `antigravity-acp/settings.json`
(`auth.type`), conversations, brain. A Google token is in the Keychain (server's naming). The app
reads only what the handshake says (`-32000` → **Needs signing in**; `authMethods`; `auth.logout`).
