# Contract: `personal/skills`

Daemon method, read-only, for Settings ▸ Agents. Listed in `DaemonAPI.Method` beside
`runtimes/list`. Mac window only; a phone or a stranger is refused as `runtimes/list` is.

**Request:** no params.

**Result:**

```json
{
  "home": "/Users/alex/.agents",
  "laidOut": true,
  "skills": [
    { "name": "grill-me", "path": "/Users/alex/.agents/skills/grill-me",
      "runtimeIDs": ["claude", "codex", "grok", "cursor", "copilot"], "clash": null },
    { "name": "review", "path": "/Users/alex/.agents/skills/review",
      "runtimeIDs": ["codex", "grok", "cursor", "copilot"],
      "clash": "/Users/alex/.claude/skills/review" }
  ],
  "instructions": { "path": "/Users/alex/.agents/AGENTS.md",
                    "runtimeIDs": ["claude", "codex", "grok", "copilot"],
                    "clashes": ["/Users/alex/.codex/AGENTS.md"] }
}
```

- `laidOut` is false on a scratch root with no `AGENTS_PERSONAL_HOME` (R4): the section then
  says the layout is off for this copy of the app, and lists nothing.
- `runtimeIDs` names installed runtimes only, in `RuntimeCatalog.builtIn` order.
- The result is computed on each call from disk; nothing is cached.

**Notification:** none. The window asks again when Settings ▸ Agents appears.
