---
diataxis: reference
devices: [mac, iphone, ipad]
description: The secrets and settings that follow you across your machines.
---

# Secrets and what follows you

The control plane keeps your secrets and the settings that follow you, and sends them to
each machine of yours when it joins and when they change
(#1760, #2410). Nobody else's machine gets them. Your secrets are in **Settings ▸ Machines ▸
Secrets**.

## Secrets

A secret is a name and a value, such as `GITHUB_TOKEN`. The name uses capital letters,
digits and `_`. Write `${GITHUB_TOKEN}` in an MCP server's `env` or `headers`, and each
machine fills it in from `~/.agents-secrets/secrets.env`.

- **Add a Secret…** keeps a new secret. **Replace…** gives it a new value. **Remove…** takes
  it out of `secrets.env` on every machine of yours.
- No client can read a value back, you included.
- Each row says how many machines have the secret.
- When a machine of yours is removed, the secrets it had say so. Change each one where it
  was issued, then replace it here.

The control plane seals each secret in an envelope of its own. A data key encrypts the
secret, and the control plane's keeper wraps the data key. On a cloud machine the keeper is
the key service in `AGENTS_CONTROL_KMS`. On a Mac it is a key in `secrets-key`, a 0600 file
beside the control key and outside the store. The store holds no readable secret.

## Settings

Each setting has one scope:

| Part | Its pane on the Mac | On each machine |
|---|---|---|
| MCP servers | Agent Configuration ▸ Connectors | `~/.agents/mcp.json`'s `mcpServers` |
| Agent configuration | Agent Configuration, its other pages | `~/.agents/AGENTS.md`, `personas/<name>.md`, `skills/<name>/SKILL.md` |
| Agent runtime choices | Chat prompt (permission); Agent Runtimes (sandbox) | `sandbox.json` and `client-permissions.json` in the settings folder |
| Cost limits | Cost | `limits.json` |
| Resources | Resources | `resources.json` |

- Agent configuration, MCP servers, runtime choices and cost limits are **Yours, on every
  machine**. Their panes have no scope switch. An edit is sent to every machine of yours.
- Resources are **This Mac's**. Each machine keeps and edits its own `resources.json`.
- Runtime sign-ins stay on each machine.

The Remote and web pages do not list these scopes under Machines. **Secrets** is a row of
its own under Machines, as on the Mac.
