# Contract: control methods for drafts

Client methods, from the Mac's sheet to the control plane. None has a web row, so
`Web/src/protocol/generated.ts` does not change.

## `providers/draftStart`

```json
{
  "form": { "name": "DigitalOcean", "kind": "stdio", "command": "npx", "args": ["-y", "@digitalocean/mcp"] },
  "secrets": { "DIGITALOCEAN_API_TOKEN": "dop_v1_…" },
  "provider": null,
  "runtimeID": "claude"
}
```

- `form` is a `ProviderAdd`. For Your commands, `kind` is `commands` and `cli` is set.
- `provider` is the provider's id in Edit…. Its secrets are merged under `secrets`, and its map
  or config and its last problem go to the agent.
- Answers `{ "draft": "<uuid>", "answered": null }` once the agent starts, or
  `{ "draft": "<uuid>", "answered": { "note": "It follows the contract: it needs no map." } }`
  or `{ … "answered": { "map": {…}, "note": "Agents ships this map." } }` or
  `{ … "answered": { "preset": "doctl", "note": "Agents has a preset for doctl." } }` when no
  agent is needed (R8).
- Refuses with the reason when the server can't be reached, the CLI isn't installed, there is no
  host on the control plane's machine, or the runtime can't run as a writer.

## `providers/draftCancel`

`{ "draft": "<uuid>" }` → `{}`. Stops the agent. Also sent by × , Back and Cancel.

## `providers/draftAnswer`

`{ "draft": "<uuid>", "question": "<uuid>", "yes": true }` → `{}`. Answers a start, stop or
check question (US3, FR-013, FR-014).

## `providers/runtimes`

`{}` → `{ "runtimes": [{ "id": "claude", "name": "Claude", "default": true }], "host": "This Mac" }`
or `{ "runtimes": [], "why": "No host runs where the control plane runs, so no agent can write here." }`.
The runtimes that can run as a writer (R2) on the control plane's host. The sheet's menu reads it.

## `control/providerDraft` (notification, to the draft's owner only)

```json
{
  "draft": "<uuid>",
  "state": "writing",
  "step": { "at": "…", "kind": "check", "text": "checked: listed 3" },
  "cost": "$0.02",
  "draftJSON": { … },
  "check": { "passed": true, "workspaces": [ … ] },
  "question": null,
  "note": null
}
```

Sent on every step and state change. In `done`, `draftJSON` is the result and `note` the
agent's last words. In `failed`, `note` is the reason. In `asking`, `question` is set.

## `providers/add` and `providers/update` (changed)

They take `draft: "<uuid>"` as well. When it names a `done` draft and the request's map (or
`commands`) is equal to the draft's, the record gets `writtenBy`. Nothing else changes: Add
still connects, checks and lists, with no agent.
