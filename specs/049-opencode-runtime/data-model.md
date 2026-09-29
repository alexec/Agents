# Data Model: OpenCode as a Runtime

## Runtime `opencode` (RuntimeCatalog)

| Field | Value |
|---|---|
| id | `opencode` |
| name | OpenCode |
| executable | `opencode` — the shim's name in `<root>/tools/opencode/current/bin/`, never looked up on the PATH |
| arguments | `["acp"]` |
| install | `.toolset(runtimeID: "opencode")` (an archive manifest) |
| usesAppCopyOnly | `true` |
| carriesConversationAcrossFolders | not listed (R9) |

## Archive manifest, version 2 (ArchiveToolset)

See [contracts/archive-manifest-v2.md](contracts/archive-manifest-v2.md).

- **Platform**: `url`, `sha256`, `size`, `command`, `arguments`, `knownBroken?`. The new field
  is `format`, derived from the URL (`zip` | `tarGz`) and never written in the manifest.
- **Platform key**: `<os>-<arch>[-baseline][-musl]`. The chooser takes the most specific key
  that is present, then the plain `<os>-<arch>`.
- **Validation**: the download's byte count must equal `size`, and its SHA-256 must equal
  `sha256`. Otherwise the install fails with 048's checksum sentence, and nothing is moved into
  place.
- **States** (unchanged from 048): not installed → downloading (bytes) → checking → unpacking →
  installed (`ok` written last) | failed(reason).

## OpenCode tool policy (ToolPolicyCatalog)

| Field | Value |
|---|---|
| removed | `task` (.agents), `todowrite` (.todos) |
| kept | — |
| residue | — (R3: both removed fully) |
| lever | `.environmentJSON(variable: "OPENCODE_CONFIG_CONTENT", value: …)` — [contract](contracts/opencode-launch.md) |
| escalationTool | nil — OpenCode's `question` tool is off over ACP; the app's `ask_form` is used |
| preferredAuthMethods | `["opencode-login"]` |

## OpenCode launch (RuntimeLaunchCatalog)

Static environment: `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_SHARE=1`,
`OPENCODE_AUTH_CONTENT=nil`, `OPENCODE_ENABLE_QUESTION_TOOL=nil`. `hiddenAuthMethods` is empty.
The sheet's note names `opencode auth logout` for signing a provider out.

## Client permission setting (061)

`ClientPermissionSettings` gains `opencode: Mode` (`ask` by default | `alwaysApprove`).
`supports("opencode") == true`.

## Lent OpenCode sign-in (servers only)

- **Source**: `$XDG_DATA_HOME/opencode/auth.json`, or else `~/.local/share/opencode/auth.json`,
  on the Mac.
- **Filter**: keep the entries whose `type` is `api` or `wellknown`. The other entries (`oauth`)
  are counted and named, never lent.
- **Carrier**: `credentials/lend`, as the variable `OPENCODE_AUTH_CONTENT` (compact JSON), in
  the OpenCode run's environment on that server only.
- **Lifetime**: that run. It is never written to the server's disk, a log or a transcript.
  Nothing is lent when the server is marked "own sign-in only".

## Usage cost

`Usage.cost` with `amount == 0` on a turn with `totalTokens > 0` is treated as unmeasured. It is
not banked in `costToDate`, and it is shown as no cost.
