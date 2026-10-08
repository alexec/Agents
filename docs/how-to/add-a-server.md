---
diataxis: how-to
devices: [mac, server]
description: Add a Linux server, or another Mac, to your control plane as a host, so every window and phone sees its projects.
---

# Add a server

A server is a Linux machine that runs agents for you. Once it is a host of your control
plane, a project can live on it: its agents run there, on its files, and keep working when
your Mac is asleep or closed. Every paired window, iPhone and iPad sees it within seconds,
with nothing to do on each.

A server joins by connecting out to the control plane over HTTPS, so nothing has to reach
it and no port needs opening. See [Projects, hosts and worktrees](../explanation/projects-hosts-worktrees.md).

## Before you start

- A window paired with your control plane. See
  [Set up Agents on this Mac](set-up-on-this-mac.md).
- A Linux machine on x86-64 or ARM64. This guide calls it `devbox.example.com`.
- The server can reach the control plane's address over HTTPS. If the control plane runs
  on your Mac, that means the server is on the same network as the Mac and can resolve its
  `.local` name.
- `curl` on the server, and its CA certificates if the control plane has a publicly
  trusted certificate.
- For installing over ssh instead of running a command yourself: the server's ssh
  destination, and a private key that logs in there. The control plane makes the ssh
  connection, so it must be able to reach the server.
- Runtimes on the server, installed and signed in there as the user your agents run as.
  See [Runtimes](../reference/runtimes.md).

## Steps

### Run a command on the server

1. In the window, open **Settings ▸ Control plane**, and click **Show** beside **Hosts**.
2. Click **Add a Server…**. With **Run a command** chosen, the sheet shows one command,
   which works once.
3. Click **Copy**.
4. On the server, as the user your agents should run as, paste the command into a shell
   and run it.

   It downloads the host into `~/.agents-server`, checks it, starts it, and says
   **devbox joined the control plane.** Where the server has a systemd user session, the
   host runs as the user service `agents-host`; to keep it running after you log out, run
   the `loginctl enable-linger` line it prints.

   The sheet says **devbox joined.** Click **Done**. The server is listed under **Hosts**,
   and has a heading of its own in the projects list.

### Or install it over ssh

1. In **Settings ▸ Control plane ▸ Hosts**, click **Add a Server…**, then choose
   **Install over ssh**.
2. Fill in **Server**, the ssh destination, such as `agents@devbox.example.com`, and a
   **Name** for it.
3. Beside **Key**, click **Choose…** and pick the private key that logs in there.
4. Click **Install**.
5. The first time, the sheet says **This server is new to the control plane. Its key is:**
   and a fingerprint. Check it matches the server: on the server,
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it. Click **Trust and
   Install**.

   The sheet ticks through **Checking the system…** and **Installing Agents…**, then says
   **devbox joined.**

The key is read once, for this install. The control plane keeps neither the key nor the ssh
connection, and afterwards the server connects out by itself like any other.

#### A server behind a bastion

A server your `~/.ssh/config` reaches through a `ProxyJump` or `ProxyCommand`, such as a
cloud workspace behind a bastion, usually cannot dial back to this Mac. Install it over ssh
the same way. The sheet then says the server **is reached through a bastion, so it connects
through a tunnel the control plane holds over ssh**.

The control plane keeps an ssh session open to the server, logging in as `ssh` does for you
from Terminal. That session forwards port 8791 on the server's loopback back to the control
plane. The server's host dials `https://127.0.0.1:8791`, and the certificate is still
checked by its pin. The key, if you chose one, is still read only for the install.

If the session drops, for example while this Mac sleeps, the server goes offline. Under
**Hosts** its line says **ssh tunnel down** and why. The control plane starts the session
again by itself. When you remove the server, the tunnel closes. A server on the same network
is set up as before, with no tunnel.

### Put a project on it

1. Click **+** (**New project**) at the top of the **Projects** list, choose the server's
   name, then **Add Folder…** or **Clone Git URL…**.
2. For a folder, choose one on the server, then click **Add as project**. A clone goes
   into your home folder on the server.

   The project appears under the server's heading. Start agents in it the usual way; the
   runtime menu offers the runtimes on the server.

### Let the server use this Mac's Claude sign-in

If Claude on the server has no sign-in of its own, the window asks **Let devbox use this
Mac's Claude sign-in?** the first time an agent there needs it. Click **Allow**, and the
server's agents use Claude as you, through this Mac, whenever this Mac is awake. The
sign-in itself stays on this Mac. Click **Don't Allow** to sign Claude in on the server
instead.

### Add another Mac

A second Mac joins the same way, with Agents Host.

1. In **Settings ▸ Control plane ▸ Hosts**, click **Add by Code…**, then **Copy**.
2. On the other Mac, install and open Agents Host. Under **Join one elsewhere**, paste the
   code and click **Join**.

   Agents Host says **This Mac runs its agents for a control plane elsewhere.** It runs no
   control plane of its own. Its projects appear under its own heading in every window.

### Remove a server

1. In **Settings ▸ Control plane ▸ Hosts**, find the server and click **Remove…**, then
   **Remove**.

   It stops connecting, and every window and device stops seeing it. Its agents are left
   running where they are, and `~/.agents-server` on the server is not touched.

## When the server is offline

If the server loses its network, or the host stops, **Hosts** marks it offline and its
projects go grey. Agents already working there keep working. The host reconnects by
itself when it can, and you see everything that happened meanwhile. **Check again** asks
at once.

## Updating a server

A server's host does not update itself yet. To update it, add it again: click **Add a
Server…** and run the new command on the server. It stops the host running there and starts
the new one on the same folder, so do it when no agent there is in the middle of a turn.

## If it doesn't work

- **That is not a host code.** The command was changed on its way. Copy it again.
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

- [Projects, hosts and worktrees](../explanation/projects-hosts-worktrees.md).
- [The control plane](../explanation/control-plane.md).
