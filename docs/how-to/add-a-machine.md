---
diataxis: how-to
devices: [mac, server]
description: Add a Linux server, or another Mac, to your control plane as a host, so every window and phone sees its folders.
---

# Add a machine

A server is a Linux machine that runs agents for you. Once it is a host of your control
plane, a folder can live on it: its agents run there, on its files, and keep working when
your Mac is asleep or closed. Every paired window, iPhone and iPad sees it within seconds,
with nothing to do on each.

A server joins by connecting out to the control plane over HTTPS, so nothing has to reach
it and no port needs opening. See [Folders, hosts and worktrees](../explanation/folders-machines-worktrees.md).

## Before you start

- A window paired with your control plane. See
  [Set up Agents on this Mac](set-up-on-this-mac.md).
- A Linux machine on x86-64 or ARM64. This guide calls it `devbox.example.com`.
- The server can reach the control plane's address over HTTPS. If the control plane runs
  on your Mac, that means the server is on the same network as the Mac and can resolve its
  `.local` name.
- `curl` on the server, and its CA certificates if the control plane has a publicly
  trusted certificate.
- For installing over ssh instead of running a command yourself: a server you can
  `ssh` to from Terminal on this Mac, by a name in `~/.ssh/config` or as `user@host[:port]`.
  The control plane makes the ssh connection with your config, agent and keys, so it must
  be able to reach the server. A control plane on another machine needs a private key.
- Runtimes on the server, installed and signed in there as the user your agents run as.
  See [Runtimes](../reference/runtimes.md).

## Steps

### Run a command on the server

1. In the window, open **Settings ▸ Machines**.
2. Click **Add a Machine…**. With **Run a command** chosen, the sheet shows one command,
   which works once.
3. Click **Copy**.
4. On the server, as the user your agents should run as, paste the command into a shell
   and run it.

   It downloads the host into `~/.agents-server`, checks it, starts it, and says
   **devbox joined the control plane.** Where the server has a systemd user session, the
   host runs as the user service `agents-host`; to keep it running after you log out, run
   the `loginctl enable-linger` line it prints.

   The sheet says **devbox joined.** and lists the git repositories it found on the server,
   unticked (see [Choose its folders](#choose-its-folders)). The server is listed under
   **Machines**, and has a heading of its own in the folders list.

The host then installs Claude by itself, into `~/.agents-server/tools`, from the pins
the control plane gives with the host (#1312). This takes about a minute and 500 MB. Until
it is done, **Runtimes** says Claude is installing. Codex installs the same way
when you click **Install** under **Runtimes**. The server needs glibc 2.28 or later. Alpine
(musl) can't run them.

### Or let it ask to join

A server can join with no code, by your approval (#994). In **Settings ▸ People**, copy the
line under **Add a machine without a code**, and run it on the server. It says **Waiting
for approval** and a short code. On your client, a card says **devbox wants to join as
you**, with the same code: click **Approve**. See
[Invite someone](invite-someone.md#approve-a-machine-that-asks-to-join).

### Or add it over ssh

1. In **Settings ▸ Machines**, click **Add a Machine…**, then choose
   **Over ssh**.
2. In **Server**, type the server. The box offers the hosts in your `~/.ssh/config`, each with
   the `user@host` ssh resolves it to; choose one, or type any `user@host`,
   `user@host:port` or `ssh://user@host:port`. Under the box, the sheet says what ssh makes of
   it, such as **ssh reaches it as agents@devbox.example.com:2222.**
3. Give it a **Name**, or leave the one guessed from the server.
4. Leave **Key** empty to log in as `ssh` does from Terminal, or click **Choose…** to use one
   key for this install only.
5. Click **Install**.

   If the server's key is already in your `known_hosts`, the install goes straight on. If it
   isn't, the sheet says **This server's key isn't in your known_hosts. Its key is:** and a
   fingerprint. Check it matches the server: on the server,
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it. Click **Trust and
   Install**. The key is trusted for this install and the server's tunnel; your
   `known_hosts` is not changed. If the key has **changed** since your `known_hosts` saw it,
   nothing is installed: remove the old key with `ssh-keygen -R` if the server was rebuilt,
   and try again.

   The sheet ticks through **Checking the system…** and **Installing Agents…**, then says
   **devbox joined.**

The key is read once, for this install. The control plane keeps neither the key nor the ssh
connection, and afterwards the server connects out by itself like any other.

#### A server that can't reach this Mac: use an ssh tunnel

A server your `~/.ssh/config` reaches through a `ProxyJump` or `ProxyCommand`, such as a
cloud workspace behind a bastion, usually cannot dial back to this Mac. For such a server,
**Use an ssh tunnel** is on by default. Turn it on for any other server that can't reach this
Mac, or off for one behind a bastion that can. Once you set it, the sheet leaves it as you set
it. Only a control plane on this Mac can hold a tunnel.

With a tunnel, the control plane keeps an ssh session open to the server, logging in as `ssh`
does for you from Terminal. That session forwards port 8791 on the server's loopback back to
the control plane, and nothing else: any `LocalForward`, `RemoteForward` or `DynamicForward` in
your config is not opened on it. The server's host dials `https://127.0.0.1:8791`, and the
certificate is still checked by its pin. The key, if you chose one, is still read only for the
install.

If the server won't open that port (something else has it, or its sshd has
`AllowTcpForwarding no`), or the session drops, the server goes offline. Under **Machines** its
line says **ssh tunnel down** and ssh's reason. The control plane starts the session again by
itself, waiting longer each time it fails, and at once when this Mac wakes or its network
changes. When you remove the server, the tunnel closes.

What the control plane passes to ssh, and how each common `~/.ssh/config` option fares, is in
[ssh options](../reference/ssh-options.md).

### Choose its folders

Nothing on the server becomes a folder by itself (#656). Once it joins, Add a Machine lists each
git repository directly inside the paths under **Auto-detect** (`~`, `~/src` and the like, `~`
being the server's home), each unticked, and the same list opens later from **Choose
Folders…** on the server's row under **Machines**, or on **This Mac**'s.

1. Tick the repositories to add. One that is already a folder is shown ticked and greyed.
2. To add a folder that is not listed, type its path on the server, such as `~/work/app`, and
   click **Add Folder**. It joins the list, ticked.
3. Click **Add N Folders**, or **Skip** to add none.

With **Suggest folders on a host** off, nothing is listed and only the folder box is there.

### Put a folder on it

1. Choose **File ▸ Add Folder On** or **File ▸ Clone Folder On**, then the server's
   name.
2. For a folder, choose one on the server, then click **Add as folder**. A clone goes
   into your home folder on the server.

   The folder appears under the server's heading. Start agents in it the usual way; the
   runtime menu offers the runtimes on the server.

### Let the server use this Mac's Claude sign-in

If Claude on the server has no sign-in of its own, the window asks **Let devbox use this
Mac's Claude sign-in?** the first time an agent there needs it. Click **Allow**, and the
server's agents use Claude as you, through this Mac, whenever this Mac is awake. The
sign-in itself stays on this Mac. Click **Don't Allow** to sign Claude in on the server
instead.

### Let the server use this Mac's git access

A private repository needs git access. If the server has no git credential helper of its
own, its git asks this Mac for one, through the control plane, over https only.

1. The first time the server's git needs access to a git server (for example
   `github.com`), every window, phone and web page asks **Let devbox use this Mac's git
   access for github.com?** Click **Allow**.

   The clone, pull or push goes on. This Mac answers from its own git (the Keychain,
   `gh auth git-credential` and the like). The credential is used for that one git command
   and is not kept on the server or logged. A push uses the same approval.
2. To take it back, in **Settings ▸ Machines**, open the server's `···` menu
   and choose **Stop Lending Git Access for github.com**. On a phone or the web page, it is
   **Settings ▸ Git access**.

Git fails at once, and says why, when this Mac is not connected or has no git access to that
git server. A server with ssh agent forwarding, or a credential helper of its own, uses its
own access and asks nothing.

### Add another Mac

A second Mac joins the same way, with Agents Host.

1. In **Settings ▸ Machines**, click **Add by Code…**, then **Copy**.
2. On the other Mac, install and open Agents Host. Under **Join one elsewhere**, paste the
   code and click **Join**.

   Agents Host says **This Mac runs its agents for a control plane elsewhere.** It runs no
   control plane of its own. Its folders appear under its own heading in every window.

### Remove a server

1. In **Settings ▸ Machines**, find the server, open its `···` menu and choose
   **Remove…**, then **Remove**.

   It stops connecting, and every window and device stops seeing it. Its agents are left
   running where they are, and `~/.agents-server` on the server is not touched.

### Or add it from a machine provider

If the server is a workspace of a provider you have added (a Docker container, a DigitalOcean
droplet, a Codespace), open **Settings ▸ Machine Providers** and choose **Add as
Host…** beside it. Add a Machine opens over ssh, with the address the provider gives already
filled in. Once the server joins, it is linked to its workspace, so it can be started and
stopped from Agents. See [Start workspaces from Agents](start-machines-from-agents.md).

**New Machine…** on a provider's card has **Clone these folders**: git URLs, one a line.
Once the new workspace joins, it clones each one, with this Mac's git access when you allow
it, and they appear under its heading.

## When the server is offline

If the server loses its network, or the host stops, **Machines** marks it offline and its
folders go grey. Agents already working there keep working. The host reconnects by
itself when it can, and you see everything that happened meanwhile. **Check again**, in
its `···` menu, asks at once.

A server linked to a provider's workspace shows **Stopped** instead when its workspace is
stopped, with **Start** on its row and over its chats on every screen.

## Updating a server

A server whose host is older than the control plane needs says **Needs an update** in
**Settings ▸ Control plane ▸ Hosts**. To update it over ssh:

1. Click the server's **···**, then **Update…**.
2. In **Server**, type the server as you reach it over ssh, as when you added it. Give a key
   if the control plane needs one. The control plane keeps neither from the install, so you
   give them again.
3. Click **Update**. If the server's key is new to this Mac, check it, then click **Trust and
   Update**.

The control plane checks that the server is that host, copies its version of Agents there,
and starts the host again. Its agents, folders and membership stay. It stops the host for a
moment, so do it when no agent there is in the middle of a turn.

A server you added with a command can be updated the same way when you can ssh to it.
Otherwise, add it again: click **Add a Machine…** and run the new command on the server.

## If it doesn't work

- **That is not a join code.** The command was changed on its way. Copy it again.
- **Hosts other than Macs run Linux.** The machine is not Linux.
- **… is not a machine the host is built for.** Agents hosts need x86-64 or ARM64.
- **This machine has no CA certificates to check the control plane with.** Install
  `ca-certificates` on the server.
- **The download did not match its checksum.** Something between the server and the
  control plane changed the download. Run the command again.
- **The host started but has not joined yet.** Read the log it names. Most often the
  server cannot reach the control plane's address, or the code had run out; add it again
  for a new command.

## Related

- [Folders, hosts and worktrees](../explanation/folders-machines-worktrees.md).
- [The control plane](../explanation/control-plane.md).
- [Start workspaces from Agents](start-machines-from-agents.md).
