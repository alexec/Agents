# Contract: `mcp.json`, sidecar and approvals

## Personal and project `mcp.json`

Same shape 054 already reads:

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "headers": { "Authorization": "Bearer ${GITHUB_TOKEN}" }
    },
    "notes": {
      "command": "node",
      "args": ["~/bin/notes-mcp.js"]
    }
  }
}
```

- Personal path: `<personalHome>/.agents/mcp.json`.
- Project path: `<folder>/.agents/mcp.json`.
- Stdio entries use `command` / `args` / `env`. HTTP uses `type` (`http` or omitted) + `url` +
  `headers`. SSE uses `type: "sse"`.
- Secret placeholders are the literal characters `$`, `{`, name, `}` — never expanded on disk.
- Key order under `mcpServers` is preserved. Keys the app did not add are left byte-for-byte
  alone (only whitespace around the spliced entry may change as needed for valid JSON).
- Unreadable / invalid JSON → no write, surface as `mcpUnreadable` (FR-008).

## Sidecar `<root>/catalog-mcp.json`

```json
{
  "servers": [
    {
      "destination": { "kind": "personal" },
      "name": "github",
      "registryName": "io.github.github/github-mcp-server",
      "version": "0.18.0",
      "run": "remote",
      "addedAt": "2026-09-26T00:00:00Z"
    }
  ]
}
```

- One row per app-added server. Remove and Replace consult this file.
- A project destination includes `"folder": "/abs/…"`.
- Missing file ≡ no managed servers.

## Approvals `<root>/mcp-approvals.json`

```json
{
  "approvalsBegan": "2026-09-26T00:00:00Z",
  "approved": {
    "/Users/a/Agents|.agents/mcp.json|postgres": "sha256-hex-of-canonical-entry"
  }
}
```

- Key: `folder|relative-file|server-name`.
- Digest: SHA-256 of canonical JSON for that one server's object (sorted keys, UTF-8, no
  insignificant whitespace). Same idea as plugin folder digests.
- `approvalsBegan`: entries that existed before this moment are treated as approved once, then
  tracked (same pattern as `PluginApprovalStore.begin…`).
- A digest mismatch → waiting for OK.

## Merge order at session start

1. App's own `agents` server.
2. Agent's chosen servers (draft / resume).
3. Project `.agents/mcp.json` entries whose digest is approved, with `${NAME}` filled.
4. Personal `mcp.json` entries, filled.
5. Plugin servers (Grok path), as today.

First of a name wins. A server that still has an unfilled `${NAME}` after reading `secrets.env`
is dropped and reported by name + missing names — never started with an empty value.
