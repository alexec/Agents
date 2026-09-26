# Contract: `personal/shared`

Daemon method, read-only, for Settings ▸ Shared ([look/](../look/README.md)). Listed in
`DaemonAPI.Method` beside `runtimes/list`. Mac window only: a phone or a stranger is refused, as
`runtimes/list` is. Replaces the earlier `personal/skills`.

**Request:** no params.

**Result** (abridged; every list is in a stable order: catalog order for runtimes, name order
otherwise):

```json
{
  "home": "/Users/alex/.agents",
  "laidOut": true,
  "runtimes": [{ "id": "claude", "name": "Claude" }, { "id": "codex", "name": "Codex" }],

  "instructions": {
    "path": "/Users/alex/.agents/AGENTS.md", "exists": true,
    "reach": { "claude": { "gets": "~/.claude/CLAUDE.md → link" },
               "codex":  { "ownCopy": "/Users/alex/.codex/AGENTS.md" },
               "cursor": { "noWay": "Cursor keeps User Rules in its own settings" },
               "gemini": "unchecked" }
  },

  "skills": [
    { "name": "dataviz", "path": "/Users/alex/.agents/skills/dataviz",
      "description": "Use whenever you are about to create any chart…",
      "source": "personal", "clash": null,
      "reach": { "claude": { "gets": "through a link in ~/.claude/skills" },
                 "codex": { "gets": "reads ~/.agents/skills" } } },
    { "name": "plover-skill", "source": { "plugin": "heron-plugin" }, "…": "…" }
  ],

  "mcp": {
    "file": "/Users/alex/.agents/mcp.json",
    "problem": null,
    "servers": [
      { "name": "github", "transport": "stdio",
        "summary": "npx -y @modelcontextprotocol/server-github",
        "envNames": ["GITHUB_TOKEN"], "headerNames": [],
        "reach": { "claude": { "gets": "sent at start" },
                   "codex": { "ownCopy": "/Users/alex/.codex/config.toml" },
                   "copilot": { "gets": "through the bridge" } } }
    ],
    "app": [{ "name": "agents", "reach": { "copilot": { "gets": "through the bridge" } } }],
    "runtimeOnly": [{ "name": "figma", "runtimeID": "codex", "file": "/Users/alex/.codex/config.toml" }]
  },

  "plugins": [
    { "name": "heron-plugin", "version": "1.0.0", "path": "/Users/alex/.agents/plugins/heron-plugin",
      "contents": { "skills": 1, "commands": 1, "agents": 0, "hooks": 0, "mcpServers": 1 },
      "reach": { "claude": { "gets": "handed at start" },
                 "codex": { "gets": "added to Codex, 25 Sep 14:02" },
                 "cursor": { "noWay": "Cursor takes no plugin from the app" } } }
  ],

  "otherFiles": [{ "path": "personas/reviewer.md", "kind": "persona" },
                 { "path": "README.md", "kind": "unused" }],

  "needsALook": [
    { "kind": "clash", "page": "mcp", "item": "github", "text": "Also in ~/.codex/config.toml. Codex uses its own copy." }
  ]
}
```

Rules:

- **Never a value from `mcp.json`**: `summary` is the command and its first arguments, or the
  URL without its query string; `envNames` and `headerNames` are names only (FR-023). An
  argument that looks like a secret (`--token=…`, or longer than 40 characters with no `/`) is
  shown as `••••`.
- `problem` is `{ "message": "…", "line": 7 }` when `mcp.json` exists but cannot be used. Then
  `servers` is empty and `needsALook` carries it.
- `reach` has a key for each installed runtime only. A runtime that is not installed is left
  out, not reported as `notInstalled`.
- `laidOut` is false on a scratch root with no `AGENTS_PERSONAL_HOME` (R4). Everything else is
  then empty, and the tab says the shared folder is off for this copy of the app.
- Computed from disk on each call. The window asks again when the tab appears and when the app
  becomes active.

**Notification:** none.
