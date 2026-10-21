---
diataxis: reference
devices: [mac, iphone, ipad]
description: The settings and secrets the control plane keeps for you and sends to each machine of yours.
---

# On Every Machine

**Settings ▸ You ▸ On Every Machine** holds what the control plane keeps for you, and sends
to each machine of yours when it joins and when it changes (#1760). Nobody else's machine
gets it.

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

Each of these parts is either the same on every machine of yours or each machine's own:

| Part | On each machine |
|---|---|
| MCP servers | `~/.agents/mcp.json`'s `mcpServers` |
| Agent configuration | `~/.agents/AGENTS.md`, `personas/<name>.md`, `skills/<name>/SKILL.md` |
| Agent runtime choices | `sandbox.json` and `client-permissions.json` in the settings folder |
| Cost limits | `limits.json` |
| Resources | `resources.json` |

- On the Mac, **Use This Mac's** takes a part from this Mac and sends it to every machine of
  yours. An MCP server with a token written in clear is refused: put the token in a secret
  first. A skill with other files beside its `SKILL.md` is left out.
- **Each Machine Its Own** gives a part back to each machine. Each machine keeps what it has
  now.
- While a part is the same on every machine, a machine's own pane does not change it. On the
  Mac, the Cost and Resources panes change it here.
- Runtime sign-ins stay on each machine.

The Remote and the web page show the same pane. They have no **Use This Mac's**, because the
settings are a machine's files.
