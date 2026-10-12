---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Let the control plane start and stop the machines your servers run on, through a workspace provider, and press Start on a stopped server from any screen.
---

# Start workspaces from Agents

Some servers stop: a cloud machine you turn off to save money, a Codespace that idles out, a
Docker container you stopped. Usually a stopped server is just offline, and you have to start
it yourself in the provider's console or in Terminal.

Give the control plane a **workspace provider** and link the server to its workspace. A
stopped server then shows **Start** on every screen. The control plane starts the machine,
waits for its agentsd to connect, and the server comes online by itself.

## Before you start

- **A control plane on one machine.** The one on your Mac works. Several copies sharing a
  bucket can't run providers yet.
- **A server already added**, or a workspace you can reach over ssh. See
  [Add a server](add-a-server.md).
- **The provider's command-line tool** on the Mac that runs the control plane, signed in:
  `docker`, `doctl`, `gh`, `coder` or `gcloud`. The provider runs there, not on the server.
  That is how it can start a server that is down.

## Add a provider

1. Open **Settings ▸ Control plane ▸ Providers** on the Mac and choose **Add Provider…**.
2. Pick the kind:
   - **Docker**: containers on the Mac that runs the control plane.
   - **DigitalOcean**: droplets with a tag. Agents reaches each one as `root@` its address
     unless you say another user.
   - **Codespaces**, **Coder**, or **Workstations** (Google Cloud Workstations).
   - **Your commands**: one workspace, given as the commands you already use to start and
     stop it, such as `cws start devstack-1`. A status command is optional; it prints
     `running` or `stopped`.
   - **MCP server**: a provider of its own, or another MCP server with a tool map. See
     [Add a workspace provider](add-a-workspace-provider.md).
3. Fill in its few fields. If it needs a token, add it under **Secrets**. A secret stays on
   the control plane and is never shown again.
4. Choose **Add**. Agents checks the provider and lists its workspaces. If it can't, the
   sheet says why, in the provider's words.

## Link a server to its workspace

- **For a server you already have:** in **Settings ▸ Control plane ▸ Hosts**, open its `···`
  menu, choose **Link to Workspace…**, pick the workspace and choose **Link**.
- **For a workspace that isn't a server yet:** start it, then choose **Add as Host…** beside
  it on the Providers page. Add a Server opens over ssh, with the provider's address filled
  in. The new server is linked to the workspace once it joins.

A workspace belongs to one server at a time: linking it to another moves the link.

## Start a stopped server

When a linked server's workspace is stopped, its row says **Stopped** and the strip over
its chats says **devbox is stopped**, with **Start**. Press it on the Mac, the iPhone, the
iPad or the browser.

The strip then says:

1. **Starting devbox…** while the provider starts the machine.
2. **Waiting for devbox to connect…** once it is up. If the server reaches the control plane
   through an ssh tunnel, the tunnel opens straight away.
3. **devbox started but agentsd didn't connect; starting it over ssh…** if agentsd hasn't
   connected after two minutes. Agents starts it over ssh, as an install leaves it, and
   installs nothing.

The strip goes away when the server is online. A timer beside the words shows how long the
start has taken so far. Pressing **Start** again on any screen while it starts does nothing
more.

If the start fails, or the server hasn't connected after ten minutes, the strip and the row
say why and offer **Start** again.

## Stop a server

Choose **Stop** on its row in **Settings ▸ Control plane ▸ Hosts**. If agents are working
there, Agents names them and asks first. The row says **Stopping…** and then **Stopped**.

## Start when used and stop when idle

A linked server's `···` menu has two settings:

- **Start when used**, on by default.
- **Stop when idle**, after 30 minutes by default.

Both are kept with the link. A prompt to a stopped server still has to wait for Start for
now. Starting it by sending a prompt, and stopping it once it has been idle, are coming
(#691).

## If it doesn't work

- **The provider can't list.** Its card says why, and shows what it last listed. Check its
  command-line tool is installed and signed in on the Mac that runs the control plane, then
  choose **List Again** in its `···` menu.
- **"workspace-commands isn't installed beside the control plane".** This build of Agents
  Host doesn't carry the command provider yet. Set `AGENTS_WORKSPACE_COMMANDS` to a build
  of it for the control plane, or wait for a build that has it.
- **The server starts but never connects.** Make agentsd start when the machine boots: on
  Linux, `loginctl enable-linger $USER` keeps the user's services running with nobody
  logged in. Or give the workspace an ssh address, so Agents can start agentsd itself.

## Related

- [Add a workspace provider](add-a-workspace-provider.md): presets, your own commands, a
  tool map, or a provider of your own.
- [Workspace providers](../reference/workspace-providers.md): the tools a provider offers.
- [The control plane](../explanation/control-plane.md): why providers run there.
