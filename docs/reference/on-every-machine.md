---
diataxis: reference
devices: [mac, iphone, ipad]
description: The secrets the control plane keeps for you, and the settings that are the same on all your machines.
---

# Secrets and the same on all your machines

The control plane keeps your secrets, and the settings that are the same on all your
machines, and sends them to each machine of yours when it joins and when they change
(#1760). Nobody else's machine gets them. Your secrets are in **Settings ▸ Machines ▸
Secrets**. Each setting has its switch at the top of its own pane (#2157).

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

| Part | Its pane on the Mac | On each machine |
|---|---|---|
| MCP servers | Agent Configuration ▸ Connectors | `~/.agents/mcp.json`'s `mcpServers` |
| Agent configuration | Agent Configuration, its other pages | `~/.agents/AGENTS.md`, `personas/<name>.md`, `skills/<name>/SKILL.md` |
| Agent runtime choices | Agent Runtimes | `sandbox.json` and `client-permissions.json` in the settings folder |
| Cost limits | Cost | `limits.json` |
| Resources | Resources | `resources.json` |

- On the Mac, each of these panes starts with **All your machines** or **This Mac only**,
  and the switch **The same on all your machines**. With no control plane, or no host on
  this Mac, the line is not there.
- Turn the switch on to take the part from this Mac and send it to every machine of yours.
  An MCP server with a token written in clear is refused: put the token in a secret first.
  A skill with other files beside its `SKILL.md` is left out.
- Turn it off to give the part back to each machine. You are asked first. Each machine
  keeps what it has now.
- While a part is the same on every machine, an edit in its pane on the Mac goes to every
  machine of yours, and a machine's own copy does not change it.
- Runtime sign-ins stay on each machine.

The Remote and the web page have no pane for each part, and they cannot read a machine's
files. **Settings ▸ Machines** ends with **The same on all your machines**: each part, where
it applies, and **Each Machine Its Own** for one that is the same everywhere. You turn one
on on the Mac. **Secrets** is a row of its own under Machines, as on the Mac.
