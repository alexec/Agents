---
diataxis: reference
description: Every file in ~/.agents, what writes it, and what stays on each machine.
---

# The `~/.agents` folder

Your settings are files in `~/.agents` in your home folder, so they can go with you to
another Mac: copy the folder, sync it, or commit it. A folder's settings are the same
idea, in the folder's own `.agents` folder.

## What is in it

| Path | What it holds | Written by |
| --- | --- | --- |
| `AGENTS.md` | Instructions every agent gets | You |
| `skills/` | Skills every agent gets | You, or **Settings ▸ Agent Configuration** |
| `personas/` | Personas you can start an agent as | You |
| `plugins/` | Plugins every agent gets | **Settings ▸ Agent Configuration** |
| `mcp.json` | Connectors (MCP servers) every agent gets. Secrets are named as `${NAME}`, never held. | You, or **Settings ▸ Agent Configuration** |
| `marketplaces.json` | Which marketplaces are on | **Manage Marketplaces…** |
| `settings/` | The settings below, one file each | The app |

The top of the folder is configuration that other tools read too. `settings/` is what the
Agents app writes. **Agent configuration, MCP servers, runtime choices and cost limits**
have one fixed scope: they belong to you and sync to every machine of yours. Runtime
sign-ins stay on each machine. Resources are stored in each machine's `resources.json` and
do not sync (#2410).

## `settings/`

| File | What it holds | Set in |
| --- | --- | --- |
| `limits.json` | The spending limits per agent and per day | **Settings ▸ Cost** |
| `retention.json` | How long archived agents are kept | **Settings ▸ Machines ▸ This Mac** |
| `workflow-limit.json` | How many approved workflows may be on in each folder. No file is the default. | **Settings ▸ Cost** |
| `person.json` | What agents call you, and your pronouns | **Settings ▸ Account** |
| `client-permissions.json` | The permission mode of each runtime | Under a supported runtime's prompt |
| `sandbox.json` | The command sandbox of each runtime | **Settings ▸ Agent Runtimes** |
| `runtime-environment.json` | The names of the variables passed through to runtimes, never their values | By hand |
| `modes.json` | The mode last chosen for each runtime | The start form |
| `display.json` | Your display choices, the same on every client: how much of a turn shows, the smart groups that are off, whether Archived folders, Status and Usage are open, the new-session form's runtime and choices, and the marketplace last chosen | Any client |
| `host.json` | The role of each of your Macs in Agents Host (its store, bucket, web remote and relay), one entry per Mac, by its local host name. The bucket's keys stay in the keychain. | Agents Host |

A file you change by hand counts at once, without a restart. A file that cannot be read is
set aside as `<name>.corrupt-<time>`, and the setting goes back to its default. For
`host.json`, the file is left as it is, and Agents Host starts with the defaults until you
mend the file or remove it.

On a server, the settings are in `~/.agents/settings` of the server's account. The Mac
sends its own settings to each server when it connects.

## What stays on each machine

These are not in `~/.agents`, because they belong to one machine, or because an agent must
not be able to change them:

- **Secrets:** `~/.agents-secrets`, a separate folder that only you can read.
- **This Mac's data:** agents, transcripts, and the sleep, resource, approval and
  retention-clock files, in `~/Library/Application Support/Agents`
  (`~/.agents-server/root` on a server). Its backups go to `backups/` in that folder unless
  you choose another: the same disk, so they do not survive the loss of the disk. Choose a
  second disk or a synced folder in **Settings ▸ Machines ▸ This Mac ▸ Backups**, or, on a
  server, back up to the control plane
  ([Back up and restore a machine](../how-to/back-up-and-restore.md)).
- **The control plane's folder** (Agents Host): `~/Library/Application Support/Agents Control`.
  It holds the store (unless it is a bucket), `secrets-key` and the certificate in `tls/`.
  The control key is in the keychain. To back them up together, and restore
  them on a new Mac, see [Back up and restore a control plane](../how-to/back-up-a-control-plane.md).
- **Caches and logs:** the system's cache and log folders. You can delete them at any time.
- **Each device's own choices:** folder folds, drafts, the new-session form's folders,
  window sizes, the selected folder, and pairing.

A scratch copy of the app, started with its own root, keeps its settings in
`<root>/settings` and never writes the real `~/.agents`, unless `AGENTS_PERSONAL_HOME`
names a home folder for it.
