# Contract: MCP catalogue methods

New and extended daemon methods for the Add sheet, Shared ▸ MCP servers and the project
section. Every one is **control-only**: the Mac window's signed connection only. None is in
`deviceMethods` or `agentMethods`. Types are in [data-model.md](../data-model.md).

`destination` is always `{"kind":"personal"}` or `{"kind":"project","folder":"/abs/path"}`.

## `catalog/search` (change)

```json
→ { "query": "github", "kind": "mcp" }
← { "results": [ { "id": "io.github.github/github-mcp-server", "title": "GitHub",
                   "description": "…", "version": "0.18.0",
                   "publisher": { "label": "github on GitHub", "namespace": "io.github.github" },
                   "known": true,
                   "runs": ["remote", "docker"],
                   "remoteHost": null } ],
    "error": null }
```

- `kind` defaults to `"skills"` (059). `"mcp"` hits the registry (R1).
- Registry order. No re-ranking. Query &lt; 2 chars → `{results:[]}` without a network call.
- Errors: `{"error":{"kind":"unreachable","host":"registry.modelcontextprotocol.io"}}`. Never an
  empty list pretending to be success when the host failed.

## `mcp/preview`

```json
→ { "result": { …MCPCatalogResult… }, "destination": { "kind": "personal" },
    "run": "remote" }
← { "preview": { "previewID": "…", "nameHere": "github", "chosenRun": "remote",
                 "commandOrURL": "https://api.githubcopilot.com/mcp/",
                 "host": "api.githubcopilot.com · GitHub's own",
                 "entry": { "type": "http", "url": "…",
                            "headers": { "Authorization": "Bearer ${GITHUB_TOKEN}" } },
                 "variables": [ { "name": "GITHUB_TOKEN", "kind": "secret",
                                  "required": true, "alreadySet": false, "description": "…" } ],
                 "reach": { "claude": "yes", … },
                 "destinationState": { "free": {} }, "problems": [] } }
```

- `run` is optional when there is only one available kind; required when several.
- Does not write `mcp.json` or `secrets.env`.
- Previews expire after 30 minutes or once used by `mcp/add`.

## `mcp/add`

```json
→ { "previewID": "…", "destination": { … },
    "secrets": { "GITHUB_TOKEN": "…" },
    "plain": { "X-MCP-Toolsets": "all" },
    "replace": false }
← { "server": { …ManagedMCPServer… } }
```

- Every required secret in the preview must be present in `secrets` or already in
  `secrets.env`. Otherwise refused with `missingSecret(name)`.
- Values in `secrets` are written to `secrets.env` first (0600), then the entry is spliced into
  `mcp.json` with only `${NAME}` (R4, R5). Values are never logged.
- `replace` must be true for `managedSame` / `managedOther`; `unmanaged` is always refused.
- For a project destination the new entry's digest is stored as approved (R6).
- Preview is consumed either way.

## `mcp/list`

```json
→ { "destination": { "kind": "project", "folder": "…" } }
← { "servers": [ { "name": "postgres", "summary": "npx -y @modelcontextprotocol/server-postgres@0.6.2",
                   "managed": null,
                   "approval": { "waiting": { "digest": "…", "isNew": true } },
                   "missingSecrets": ["DATABASE_URL"], "entryDigest": "…" } ],
    "problem": null }
```

- Personal list is also folded into `personal/shared` (frame A); this method feeds the project
  section and the sheet's "added" marks.

## `mcp/approve`

```json
→ { "destination": { "kind": "project", "folder": "…" },
    "name": "postgres", "digest": "…" }
← { "servers": [ …same as mcp/list… ] }
```

- Digest must match the file's current entry or the call is refused (stale). Same pattern as
  `plugins/approve`.

## `mcp/set-secret`

```json
→ { "name": "SENTRY_AUTH_TOKEN", "value": "…" }
← { "set": true }
```

- Creates `secrets.env` at 0600 if missing. Replaces an existing name. Value never logged, never
  returned. `personal/shared` afterwards shows the name as set.

## `mcp/remove`

```json
→ { "destination": { … }, "name": "context7", "forgetSecret": "CONTEXT7_API_KEY" }
← { "ok": true }
```

- Only when the sidecar names `name` at that destination. Otherwise
  `{"error":{"kind":"unmanaged","path":…}}`.
- Removes the entry from `mcp.json`, the sidecar row, and (project) the approval row.
- `forgetSecret` is optional. Allowed only when no other managed or listed entry still
  references that name; otherwise refused. Unticked → secret stays.

## Errors

Shared with 059 where the kind matches: `unreachable`, `noPersonalHome`, `unmanaged`,
`mcpUnreadable`. MCP-specific: `missingSecret(name)`, `staleDigest`, `secretStillInUse(name)`,
`previewExpired`, `noRunnableWay`.

Wire failure code: reuse `DaemonAPI.Failure.catalogRefused` (-32080) with an `MCPCatalogError`
payload, or a sibling `-32081` if mixing skill/MCP payloads is awkward — pick one in
implementation and keep tests on the payload kind.

## Logging

Log method name, registry id, short name, destination kind, and error kind only. Never a
secret value, never a header value, never `secrets.env` contents.
