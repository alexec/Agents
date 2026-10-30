---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Let the control plane start and stop the machines your servers run on, through a machine provider, and press Start on a stopped server from any screen.
---

# Start machines from Agents

Some servers stop: a cloud machine you turn off to save money, a Codespace that idles out, a
Docker container you stopped. Usually a stopped server is just offline, and you have to start
it yourself in the provider's console or in Terminal.

Give the control plane a **machine provider** and link the server to its machine. A
stopped server then shows **Start** on every screen. The control plane starts the machine,
waits for its agentsd to connect, and the server comes online by itself.

## Before you start

- **A control plane on one machine.** The one on your Mac works. Several copies sharing a
  bucket can't run providers yet.
- **A server already added**, or a machine you can reach over ssh. See
  [Add a machine](add-a-machine.md).
- **The provider's command-line tool** on the Mac that runs the control plane, signed in:
  `docker`, `doctl`, `gh`, `coder` or `gcloud`. The provider runs there, not on the server.
  That is how it can start a server that is down.

## Add a provider

1. Open **Settings ▸ Machine Providers** on the Mac and choose **Add Provider…**.
2. Pick the kind:
   - **Docker Containers**: containers on the Mac that runs the control plane.
   - **DigitalOcean Droplets**: droplets with a tag. Agents reaches each one as `root@` its address
     unless you say another user.
   - **GitHub Codespaces**, **Coder Machines**, or **Google Cloud Workstations**.
   - **Your commands**: one machine, given as the commands you already use to start and
     stop it, such as `cws start devstack-1`. A status command is optional; it prints
     `running` or `stopped`.
   - **MCP server**: a provider of its own, or another MCP server with a tool map. See
     [Add a machine provider](add-a-machine-provider.md).
3. Fill in its few fields. If it needs a token, add it under **Secrets**. A secret stays on
   the control plane and is never shown again.
4. Choose **Add**. Agents checks the provider and lists its machines. If it can't, the
   sheet says why, in the provider's words.

## Link a server to its machine

- **For a server you already have:** in **Settings ▸ Machines**, open its `···`
  menu, choose **Link to Provider…**, pick the machine and choose **Link**.
- **For a machine that isn't a server yet:** start it, then choose **Add as Machine…** beside
  it on the Providers page. Add a Machine opens over ssh, with the provider's address filled
  in. The new server is linked to the machine once it joins.

A machine belongs to one server at a time: linking it to another moves the link.

## Start a stopped server

When a linked server's machine is stopped, its row says **Stopped** and the strip over
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

Choose **Stop** on its row in **Settings ▸ Machines**. If agents are working
there, Agents names them and asks first. The row says **Stopping…** and then **Stopped**.

## Start when used and stop when idle

A linked server's `···` menu has three settings:

- **Start when used**, on by default.
- **Stop when idle**, after 30 minutes by default.
- **Start for scheduled workflows**, on by default.

All three are kept with the link.

### Start when used

With **Start when used** on, you don't have to press **Start**. Send a prompt to an agent on
the stopped server, or start a new agent in one of its folders, on the Mac, the iPhone or
the web page:

- The control plane keeps what you sent and starts the machine.
- The chat shows your prompt as a dashed bubble, with **Waiting for devbox to start** under
  it. A new agent's chat opens at once with its first prompt waiting the same way.
- When the server connects, the prompt goes, once, in the order it was sent. A new agent is
  made then, and its chat opens.

What was sent is kept by the control plane, not by the app. You can close the app or lock the
phone, and it still goes. Up to 20 can wait for one server.

- **To take one back**, press × beside it. The machine keeps starting.
- **If the start fails**, each waiting prompt says **Not sent** and why, with **Try Again**.
- **Attachments can't wait.** Send the words alone, or start the server first.

Only prompts and new agents start a machine. Reading a chat or a file on a stopped server
doesn't. With **Start when used** off, a prompt to a stopped server is refused, and its strip
offers **Start**.

### Stop when idle

A machine costs money while it runs. With **Stop when idle** on, Agents stops it once its
server has been idle for the whole time you chose: 15, 30 or 60 minutes, or 2 hours. Idle
means:

- no turn running,
- no agent waiting on your answer,
- and no terminal or folder shell open.

A turn starting in that time starts the count again. When Agents stops it, its row and the
strip over its chats say **devbox was stopped by Agents after 30 minutes idle**. With **Start
when used** on as well, your next prompt starts it again.

A server on a build of Agents from before this never says whether it is idle, so it is never
stopped as idle. Update it from its row.

### Start for scheduled workflows

A stopped server runs nothing, so its scheduled workflows would not run. With **Start for
scheduled workflows** on, Agents starts the machine a little before the server's next
scheduled workflow is due:

- The server's own clock still fires the workflow. Agents only starts the machine.
- It starts it 5 minutes before the due time. After the first start, it uses how long the
  last start took, plus 2 minutes.
- It starts it once for each due time.
- **Stop when idle** does not stop a server whose next scheduled workflow is due within its
  idle time. After the run, the server is idle again and stops as usual.

A stopped server's row, and the strip over its chats on the Mac, the iPhone and the web page,
say when it starts and for which workflow: **Starts at 02:55 for Nightly review**. **Stop**
says it too, before it stops the server.

With the switch off, the server stays stopped, and its scheduled workflows don't run while it
is stopped. Its row warns you of that when it has some and **Stop when idle** is on. A server
on a build of Agents from before this doesn't say when its workflows are due, so it is not
started for them, and its row warns you the same way.

Only scheduled workflows start a server. An event (such as `issue.opened`) is still heard only
when the server is next up. Agents knows only the due time the server last sent: a workflow
added while it is stopped is not seen until it is next up.

## Make a new machine

For a provider that can make machines, its card in **Settings ▸ Control plane ▸
Providers** has **New Machine…**.

1. Give it a name, and make its choices: its size or region, say.
2. Choose **Make…**. Agents says what it will make and, if the provider says, what it costs.
3. Choose **Make**.

The new machine shows **Joining…** until it has installed Agents and joined. Then it is
linked to its host. A provider that can't install on first boot opens **Add a Machine** with
the new machine filled in, as **Add as Machine…** does.

To delete one, choose **Delete Machine…** in its server's `···` menu on Settings ▸ Machines.
Agents names what is lost first: the machine, everything on its disk, and the server with
its agents.

## Let an agent start a session on another machine

Some work has to run on a particular machine, such as a bug that only shows on the PC. An
agent can start a session there with `start_session`, naming the machine and a folder on
it (#2887). `list_machines` gives the agent the names of all your machines.

1. The agent asks first. Its question card says the machine, the folder and the task.
2. Choose **Start it**. The session starts on that machine and shows in your list under it.
   If the machine is stopped, Agents starts it, and the session starts when it connects.
   The session's chat says which agent started it, and on which machine.

The folder must be on that machine already. To put it there, use **Send to ‹server›…**
(see [Send a folder to a server](send-a-folder-to-a-machine.md)). The agent that asked
sees the new session in its own list of sessions, and can read it, message it, wait for it,
stop it and archive it, as for a session in its own folder (#2927). No other agent can.
The new session counts in the helper limits of the asking agent's folder until it is
archived. If those limits are full, the start is refused; it is not queued. Its prompt
says what to do with the result, for example push a branch.

The agent can't reach a session that started later because its machine was stopped: that
session has no id when the agent asks. If the asking machine is offline when the session
ends, the agent learns of the end the next time it asks for the session.

## If it doesn't work

- **The provider can't list.** Its card says why, and shows what it last listed. Check its
  command-line tool is installed and signed in on the Mac that runs the control plane, then
  choose **List Again** in its `···` menu.
- **"machine-commands isn't installed beside the control plane".** This build of Agents
  Host doesn't carry the command provider yet. Set `AGENTS_WORKSPACE_COMMANDS` to a build
  of it for the control plane, or wait for a build that has it.
- **The server starts but never connects.** Make agentsd start when the machine boots: on
  Linux, `loginctl enable-linger $USER` keeps the user's services running with nobody
  logged in. Or give the machine an ssh address, so Agents can start agentsd itself.

## Related

- [Add a machine provider](add-a-machine-provider.md): presets, your own commands, a
  tool map, or a provider of your own.
- [Machine providers](../reference/machine-providers.md): the tools a provider offers.
- [The control plane](../explanation/control-plane.md): why providers run there.
