---
diataxis: reference
description: Every file in ~/.agents, what writes it, and what stays on each machine.
---

# The `~/.agents` folder

Your settings are files in `~/.agents` in your home folder, so they can go with you to
another Mac: copy the folder, sync it, or commit it. A project's settings are the same
idea, in the project's own `.agents` folder.

## What is in it

| Path | What it holds | Written by |
| --- | --- | --- |
| `AGENTS.md` | Instructions every agent gets | You |
| `skills/` | Skills every agent gets | You, or **Settings ▸ Agent Configuration** |
| `personas/` | Personas you can start an agent as | You |
| `plugins/` | Plugins every agent gets | **Settings ▸ Agent Configuration** |
| `mcp.json` | MCP servers every agent gets. Secrets are named as `${NAME}`, never held. | You, or **Settings ▸ Agent Configuration** |
| `marketplaces.json` | Which marketplaces are on | **Manage Marketplaces…** |
| `chat/` | The chat project, for chats without a project | The app |
| `settings/` | The settings below, one file each | The app |

The top of the folder is configuration that other tools read too. `settings/` is what the
Agents app writes.

## `settings/`

| File | What it holds | Set in |
| --- | --- | --- |
| `limits.json` | The spending limits per agent and per day | **Settings ▸ Spending** |
| `retention.json` | How long archived agents are kept | **Settings ▸ Mac** |
| `workflow-limit.json` | How many workflows may be on. No file is the default. | **Settings ▸ Spending** |
| `person.json` | What agents call you, and your pronouns | **Settings ▸ Account** |
| `client-permissions.json` | The permission mode of each runtime | **Settings ▸ Agent Runtimes** |
| `sandbox.json` | The command sandbox of each runtime | **Settings ▸ Agent Runtimes** |
| `runtime-environment.json` | The names of the variables passed through to runtimes, never their values | By hand |
| `modes.json` | The mode last chosen for each runtime | The start form |
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
  (`~/.agents-server/root` on a server).
- **Caches and logs:** the system's cache and log folders. You can delete them at any time.
- **Each device's own choices:** folds, drafts, window sizes, the selected project, and
  pairing.

A scratch copy of the app, started with its own root, keeps its settings in
`<root>/settings` and never writes the real `~/.agents`, unless `AGENTS_PERSONAL_HOME`
names a home folder for it.
