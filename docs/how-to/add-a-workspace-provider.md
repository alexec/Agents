---
diataxis: how-to
devices: [mac, server]
description: Make anything that can start and stop a machine a workspace provider - a preset, your own commands, a tool map over another MCP server, or a server of your own.
---

# Add a workspace provider

A workspace provider is an MCP server that lists workspaces, starts them and stops them.
Agents talks to every provider in the same way, so it has no code for any one cloud. There
are three ways to make one, and only the last needs any code.

## A preset, or your own commands

Agents ships one provider, the **command provider**. Each of its workspaces is a few
shell commands, and its presets fill those in for the common tools:

| Preset | It needs, where the control plane runs | Workspaces |
| --- | --- | --- |
| Docker | `docker` | the containers you name |
| DigitalOcean | `doctl`, signed in | droplets with a tag |
| Codespaces | `gh`, signed in | your codespaces, or one repository's |
| Coder | `coder`, signed in, after `coder config-ssh` | your Coder workspaces |
| Workstations | `gcloud`, signed in | one cluster and configuration's workstations |

For anything else, choose **Your commands** and give:

- **Start** and **Stop**: the commands you would type, such as `cws start devstack-1`.
- **Status** (optional): a command that prints `running` or `stopped`. Without it, Agents
  goes by what it last did.
- **ssh**: how the control plane's Mac reaches it, such as `devstack-1.cws` or
  `alex@devbox.example -p 2222`. Agents uses it to add the workspace as a server, and to start
  agentsd if it doesn't start on boot.

The commands run with `/bin/sh` on the Mac that runs the control plane, as you, never as
root. A secret you add goes to them as an environment variable of the same name: write
`$TOKEN` in a command to use it.

To make and delete workspaces from Agents as well, configure the command provider with a
`list` command and add:

- **`create`**: the command that makes one. `${name}`, `${firstBoot}` and each option's
  key are filled in, each as one shell word. With `${firstBoot}` in it, the new workspace
  installs Agents on its first boot. Without it, you add it over ssh once it is made.
- **`delete`**: the command that deletes one, with `${id}` and its list's columns.
- **`options`**: the New Workspace form, as a JSON Schema object.

No preset makes workspaces, so this needs **An MCP server** or a provider configured by hand.

The command provider is the `workspace-commands` binary. The control plane looks for it
beside itself, then where `AGENTS_WORKSPACE_COMMANDS` says, then on its `PATH`. Its configuration is described in full in
[its contract](https://github.com/alexec/Agents/blob/main/specs/691-workspace-providers/contracts/command-provider.md).

## A tool map, for a provider's own MCP server

Some providers have an MCP server of their own, with tools named their own way. Choose
**MCP server**, give its command or address, and write a **tool map**. The map says which of
its tools lists, starts and stops, and where the workspaces are in what it answers.

Agents ships one for DigitalOcean's server: choose **Use DigitalOcean's** under the tool map.
It fills in `npx -y @digitalocean/mcp`, the map below, and a `DIGITALOCEAN_API_TOKEN`
secret for your token. It needs Node where the control plane runs.

```json
{
  "list": {
    "tool": "droplet-list",
    "arguments": { "PerPage": 200 },
    "items": "droplets",
    "id": "id",
    "name": "name",
    "state": "status",
    "ssh": "root@{networks.v4[0].ip_address}",
    "cost": "${size.price_hourly}/hour while running",
    "states": { "active": "running", "new": "starting", "off": "stopped", "archive": "stopped" }
  },
  "start":  { "tool": "power-on-droplet", "arguments": { "ID": "{id:number}" } },
  "stop":   { "tool": "power-off-droplet", "arguments": { "ID": "{id:number}" } },
  "delete": { "tool": "droplet-delete", "arguments": { "ID": "{id:number}" } }
}
```

It lists every droplet in the account. Its server's `droplet-create` can't run a command on
first boot, so make droplets in DigitalOcean, or use the `doctl` preset.

- A path is dotted keys, with `[0]` for an item of a list.
- `{path}` inside text is filled in from the workspace.
- `{id}` in arguments is the workspace's id, and `{id:number}` the same as a number.
- `create`, `delete` and `options` are optional, with the same shape as `start`.
  `create`'s arguments take `{name}`, `{firstBoot}`, `{options}` and each choice's key, and
  `"firstBootRuns": true` says the server runs `{firstBoot}` on the new workspace.
- `states` turns the provider's words into running, starting, stopping or stopped.

The tool names in this example show the shape. Check the server's own tool list for the
real ones. When you add it, Agents checks every tool the map names is there, and names any
that isn't.

For a server at an address, its one secret is sent as `Authorization: Bearer` and the
secret. For a command, secrets are its environment.

## A provider of your own

Any MCP server that offers `workspaces_list`, `workspace_start` and `workspace_stop` is a
provider as it is. It needs no map. The tools, their arguments and their answers are in
[Workspace providers](../reference/workspace-providers.md).

## Related

- [Start workspaces from Agents](start-workspaces-from-agents.md): link a server and press
  Start.
- [Add an MCP server by hand](add-an-mcp-server-by-hand.md): MCP servers for agents, which are
  set up per project, not on the control plane.
