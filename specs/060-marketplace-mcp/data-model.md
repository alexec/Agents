# 060 · Data model

Wire shapes are in [contracts/mcp-methods.md](contracts/mcp-methods.md). File formats are in
[contracts/mcp-json.md](contracts/mcp-json.md) and
[contracts/secrets-env.md](contracts/secrets-env.md).

## Destination

Where a server goes. Same shape as 059's skill destination.

| Field | Type | Notes |
|---|---|---|
| `kind` | `personal` \| `project` | |
| `folder` | path | Only for `project`. Project or worktree folder the page shows. |

Resolves to:

- **personal**: `<personalHome>/.agents/mcp.json`. No personal home → no You destination.
- **project**: `<folder>/.agents/mcp.json`. Mac projects only (R6).

## MCPCatalogResult

One row in frame B.

| Field | Type | From |
|---|---|---|
| `id` | string | Registry `server.name` (`io.github.github/github-mcp-server`) |
| `title` | string | `title`, or the segment after `/` |
| `description` | string | Registry description (may be truncated by the registry) |
| `version` | string | Latest version string |
| `publisher` | Publisher | R8 |
| `known` | bool | R8 |
| `runs` | [RunKind] | Ways this Mac can run it: `remote`, `npx`, `uvx`, `docker` |
| `remoteHost` | string? | Set when a remote's host is not the publisher's own |

**Publisher**: `label` (e.g. `github on GitHub`), `namespace` (registry name prefix before `/`).

**RunKind**: `remote` \| `npx` \| `uvx` \| `docker`. A kind listed by the registry but missing
on this Mac is returned as `unavailable(RunKind)` for the grey chip on the row.

The **added** mark is derived from the sidecar + destination listing, as skills do.

## MCPPreview

Frame C. Built from the detail response; nothing staged on disk beyond a small JSON blob in
memory / a short-lived preview id in the daemon.

| Field | Type | Notes |
|---|---|---|
| `previewID` | UUID | |
| `result` | MCPCatalogResult | |
| `nameHere` | string | Short name under `mcpServers` (R3) |
| `chosenRun` | RunKind | Person's choice when more than one |
| `commandOrURL` | string | Exact command line, or URL |
| `host` | string? | Remote host + "publisher's own" / named third party |
| `entry` | JSON object | Exactly what will be written under `nameHere`, with `${NAME}` |
| `variables` | [MCPVariable] | |
| `reach` | [String: Reach] | Per runtime, for `chosenRun`'s transport |
| `destinationState` | MCPDestinationState | |
| `problems` | [MCPPreviewProblem] | Any fatal problem → Add unavailable |

**MCPVariable**: `name`, `description`, `kind` (`secret` \| `plain`), `required` (bool),
`alreadySet` (bool — name present in `secrets.env`), `placeholder` (optional default for plain).

**MCPDestinationState**:

- `free`
- `managedSame` — sidecar already has this registry id here (Add becomes Replace)
- `managedOther(registryName)` — sidecar has a different registry server under this short name
- `unmanaged(path)` — short name taken by a hand-written entry; Add refused

**MCPPreviewProblem**: `unreachable(host)`, `noRunnableWay`, `nameTakenUnmanaged`,
`mcpUnreadable(path)`, `noPersonalHome`.

## ManagedMCPServer

What the sidecar and Shared / project rows show for something the app added.

| Field | Type | Notes |
|---|---|---|
| `name` | string | Short name in `mcp.json` |
| `registryName` | string | Full registry id |
| `version` | string | Pinned when added |
| `run` | RunKind | |
| `addedAt` | date | |
| `destination` | Destination | |

## ProjectMCPServer (listing)

Frame D row.

| Field | Type | Notes |
|---|---|---|
| `name` | string | |
| `summary` | string | Command or URL, with `${NAME}` still visible |
| `managed` | ManagedMCPServer? | Nil for hand-written / pulled without sidecar |
| `approval` | `approved` \| `waiting(digest, isNew)` | |
| `missingSecrets` | [string] | Names not in `secrets.env` |
| `entryDigest` | string | Current digest of the entry |

## SecretsEnv

In-memory view of `secrets.env`: ordered entries `{name, set: true}` only — **never the
value** in any Codable sent to the app. Writes go through `mcp/set-secret` with the value
only on the request, which is not logged.
