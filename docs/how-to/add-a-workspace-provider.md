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
| Docker Containers | `docker` | the containers you name, or the containers labelled `agents.workspace` |
| DigitalOcean Droplets | `doctl`, signed in | droplets with a tag |
| GitHub Codespaces | `gh`, signed in | your codespaces, or one repository's |
| Coder Workspaces | `coder`, signed in, after `coder config-ssh` | your Coder workspaces |
| Google Cloud Workstations | `gcloud`, signed in | one cluster and configuration's workstations |

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
- **`options`**: the New Workspace form, as a JSON Schema object. A property's `default`
  fills in a choice the form leaves empty.

The Docker preset makes workspaces when you give it an **Image** and no containers. New
Workspace… runs `docker run -d --name <name> --label agents.workspace <image>`, then the
install command in it with `docker exec`, so the container joins by itself. The image must
keep running and have `curl`. Delete Workspace… runs `docker rm -f -v`, which also removes
the container's anonymous volumes. Any other preset needs **An MCP server** or a provider
configured by hand to make workspaces.

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

## Let an agent write it

For **MCP server** and **Your commands**, an agent can write the map or the commands for you.
The agent runs on the host on the Mac that runs the control plane, on a runtime that can turn
off its own tools. For now, that runtime is Claude. The sheet shows a runtime menu when more
than one runtime can write.

1. Give the server's command or address, or the **CLI** that your commands use (`cws`).
   Add the secrets the server or CLI needs.
2. Click **Write It for Me**. The control plane reads the server's tools, or runs
   `cws --help`. Then it starts the agent with what it read.
3. Under the field, a line shows each step: "Writing… read 41 tools · checked: listed 3".
   **Details…** shows every step. Click **×** to stop. Nothing is kept.
4. When the agent is done, the map or the commands are in the form's own fields, with
   the list that its last check got, and "Written by Claude. Read it before you add it."
   Read it, change it if you want, then click **Add**. Add checks it again, as always.

Some cases need no agent:

- A server that follows the contract needs no map. The sheet says so.
- A server that the DigitalOcean map fits gets that map.
- A CLI that has a preset (`docker`, `doctl`, `gh`, `coder`, `gcloud`) gets a button for
  that preset.

What the agent can and cannot do:

- It has no tools of its runtime's own. It cannot run commands, read files, or reach the
  network. It has only seven tools, which the control plane answers for it.
- It never sees a secret's value. Where a value would show, it sees `${NAME}`.
- The control plane runs `cws ‹words› --help` only for subcommands that the help printed.
  It runs a check alone only if the check is plainly a list. For any other check, the sheet
  asks you first, with **Run Check**.
- The agent can ask to start or stop one workspace to prove the map. The sheet asks you
  each time, with the workspace and its cost. **Don't**, or no answer in 2 minutes, is a no.
  A workspace that you start this way stays running until you stop it.
- It has 5 minutes, 8 checks and 40 tool calls. Then the sheet shows its last draft.

When a provider's server changes, use **Write the Map Again…** (or **Write the Commands
Again…**) in its card's `···` menu. The agent starts from the map that the provider has
now. **Save** keeps the server, the secrets and the linked hosts. When Add refuses a server
that a map would fix, the refusal has **Write a Tool Map**.

Start and Stop never use the agent: they use the map that you kept.

## A provider of your own

Any MCP server that offers `workspaces_list`, `workspace_start` and `workspace_stop` is a
provider as it is. It needs no map. The tools, their arguments and their answers are in
[Workspace providers](../reference/workspace-providers.md).

## Related

- [Start workspaces from Agents](start-workspaces-from-agents.md): link a server and press
  Start.
- [Add an MCP server by hand](add-an-mcp-server-by-hand.md): MCP servers for agents, which are
  set up per project, not on the control plane.
