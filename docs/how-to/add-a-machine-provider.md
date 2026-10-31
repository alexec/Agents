---
diataxis: how-to
devices: [mac, iphone, ipad, web, server]
description: Make anything that can start and stop a machine a machine provider - a preset, your own commands, a tool map over another MCP server, or a server of your own.
---

# Add a machine provider

A machine provider is an MCP server that lists machines, starts them and stops them.
Agents talks to every provider in the same way, so it has no code for any one cloud. There
are three ways to make one, and only the last needs any code.

## A preset, or your own commands

Agents ships one provider, the **command provider**. Each of its machines is a few
shell commands or web requests, and its presets fill those in for the common tools.

DigitalOcean, GitHub Codespaces and Coder can be reached in two ways. Add Provider shows
**Its API** first: a token, and nothing to install (#1119). **Its CLI** uses the CLI, signed
in, as before.

| Preset | Through its API, it needs | Through its CLI, it needs | Machines |
| --- | --- | --- | --- |
| Docker Containers | — | `docker` | the containers you name, or the containers labelled `agents.machine` |
| DigitalOcean Droplets | a token with custom scopes: droplet read and update (and create and delete, to make and delete droplets) | `doctl`, signed in | droplets with a tag |
| GitHub Codespaces | a token: fine-grained with Codespaces lifecycle admin, or classic with `codespace`; and `gh` for ssh, after `gh codespace ssh --config >> ~/.ssh/config` | `gh`, signed in | your codespaces, or one repository's |
| Coder Machines | the deployment's address and a session token (`coder tokens create`); and `coder` for ssh, after `coder config-ssh` | `coder`, signed in, after `coder config-ssh` | your Coder machines |
| Google Cloud Workstations | — | `gcloud`, signed in | one cluster and configuration's workstations |
| AWS EC2 Instances | an IAM user's access key (the policy is below) | — | instances with a tag in one region |

The token goes in only as the provider's secret. It is sent in a request's header, never in
an address, a log or an error. A codespace and a Coder machine have no ssh port of their
own, so ssh to them still goes through `gh` or `coder`, as the ssh ProxyCommand; the
Providers page says "needs gh for ssh" or "needs coder for ssh". A droplet is reached with
plain ssh to its public address, and so is an EC2 instance.

AWS EC2 Instances is through its API only, with an IAM user's access key ID and secret
access key. The smallest policy lists the instances and starts and stops only the ones with
the tag (here `agents`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ec2:DescribeInstances", "Resource": "*" },
    { "Effect": "Allow", "Action": ["ec2:StartInstances", "ec2:StopInstances"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": { "Null": { "aws:ResourceTag/agents": "false" } } }
  ]
}
```

`ec2:DescribeInstances` can't be limited to some instances: AWS allows it on all or none.
The preset makes and deletes no instances.

For anything else, choose **Your commands** and give:

- **Start** and **Stop**: the commands you would type, such as `cws start devstack-1`.
- **Status** (optional): a command that prints `running` or `stopped`. Without it, Agents
  goes by what it last did.
- **ssh**: how the control plane's Mac reaches it, such as `devstack-1.cws` or
  `alex@devbox.example -p 2222`. Agents uses it to add the machine as a server, and to start
  agentsd if it doesn't start on boot.

The commands run with `/bin/sh` on the Mac that runs the control plane, as you, never as
root. A secret you add goes to them as an environment variable of the same name: write
`$TOKEN` in a command to use it.

To make and delete machines from Agents as well, configure the command provider with a
`list` command and add:

- **`create`**: the command that makes one. `${name}`, `${firstBoot}` and each option's
  key are filled in, each as one shell word. With `${firstBoot}` in it, the new machine
  installs Agents on its first boot. Without it, you add it over ssh once it is made.
- **`delete`**: the command that deletes one, with `${id}` and its list's columns.
- **`options`**: the New Machine form, as a JSON Schema object. A property's `default`
  fills in a choice the form leaves empty.

The Docker preset makes machines when you give it an **Image** and no containers. New
Machine… runs `docker run -d --name <name> --label agents.machine <image>`, then the
install command in it with `docker exec`, so the container joins by itself. The image must
keep running and have `curl`. Delete Machine… runs `docker rm -f -v`, which also removes
the container's anonymous volumes.

DigitalOcean through its API makes droplets too. New Machine… makes a droplet with the
tag, in the region, size and image you choose (an image with systemd, such as
`ubuntu-24-04-x64`). Its first boot makes a user, `agents`, with root's ssh keys, and
installs Agents as that user, never as root. The host starts with the droplet. Delete
Machine… deletes the droplet. Any other preset needs **An MCP server** or a provider
configured by hand to make machines.

The command provider is the `machine-commands` binary. The control plane looks for it
beside itself, then where `AGENTS_WORKSPACE_COMMANDS` says, then on its `PATH`. Its configuration is described in full in
[Machine providers](../reference/machine-providers.md#the-command-provider).

## A tool map, for a provider's own MCP server

Some providers have an MCP server of their own, with tools named their own way. Choose
**MCP server**, give its command or address, and write a **tool map**. The map says which of
its tools lists, starts and stops, and where the machines are in what it answers.

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
first boot, so use the DigitalOcean preset through its API to make droplets.

- A path is dotted keys, with `[0]` for an item of a list.
- `{path}` inside text is filled in from the machine.
- `{id}` in arguments is the machine's id, and `{id:number}` the same as a number.
- `create`, `delete` and `options` are optional, with the same shape as `start`.
  `create`'s arguments take `{name}`, `{firstBoot}`, `{options}` and each choice's key, and
  `"firstBootRuns": true` says the server runs `{firstBoot}` on the new machine.
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
- The agent can ask to start or stop one machine to prove the map. The sheet asks you
  each time, with the machine and its cost. **Don't**, or no answer in 2 minutes, is a no.
  A machine that you start this way stays running until you stop it.
- It has 5 minutes, 8 checks and 40 tool calls. Then the sheet shows its last draft.

When a provider's server changes, use **Write the Map Again…** (or **Write the Commands
Again…**) in its card's `···` menu. The agent starts from the map that the provider has
now. **Save** keeps the server, the secrets and the linked hosts. When Add refuses a server
that a map would fix, the refusal has **Write a Tool Map**.

Start and Stop never use the agent: they use the map that you kept.

## On the iPhone, the iPad and the web page

The Remote and the web page add, edit and remove the API presets: DigitalOcean Droplets,
GitHub Codespaces, Coder machines, Google Compute Engine VMs and AWS EC2 instances.

- **iPhone and iPad:** open **Settings**, tap **Machine providers**, then tap
  **Add Provider…**.
- **Web page:** open **Settings**, go to **Machine providers**, then click **Add
  Provider…**.

Each one asks for the same fields and the same token as the Mac. The token goes to the
control plane, and the page never shows it again. **List Again**, **Edit…** and
**Remove…** are on each provider, and **Stop** and **Unlink** on each linked host.

Add Docker, Cloud Workstations, your own commands and MCP servers in the Mac app. They need
a CLI or a map, which the Remote and the page do not edit.

## A provider of your own

Any MCP server that offers `workspaces_list`, `workspace_start` and `workspace_stop` is a
provider as it is. It needs no map. The tools, their arguments and their answers are in
[Machine providers](../reference/machine-providers.md).

## Related

- [Start machines from Agents](start-machines-from-agents.md): link a server and press
  Start.
- [Add a connector by hand](add-a-connector-by-hand.md): connectors (MCP servers) for agents, which are
  set up per folder, not on the control plane.
