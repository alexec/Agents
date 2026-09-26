---
diataxis: how-to
devices: [mac, server]
description: Add a Linux server over ssh so agents can work on a project that lives there.
---

# Add a Linux server

A server is a Linux machine you reach with `ssh`. Once it is added, a project can live on
it: its agents run there, on its files, and keep working when your Mac is asleep or
closed. You follow them from the Mac as you would any other project.

## Before you start

- A Linux machine on x86-64 or ARM64. This guide calls it `devbox.example.com`.
- `ssh` from this Mac to it with a key and no typing: `ssh devbox.example.com` (or an
  alias from `~/.ssh/config`) should log you straight in. Agents uses your own ssh setup,
  including your keys, ssh-agent and any jump hosts.
- One agent runtime installed on the server and signed in there, as that user. For
  example, for Claude Code: install it on the server, run `claude` there once and sign
  in. See [Reference](../reference/index.md) for what each runtime needs.

- If you built Agents yourself, build the server's helper once before building the app:
  `./scripts/build-linux-agentsd.sh`. It needs the swift.org toolchain and Static Linux
  SDK that match Xcode's Swift. Without it, adding a server says its system is not
  supported.

Nothing needs installing on the server by hand beyond the runtime. Agents copies its own
helper into `~/.agents-server` and opens no network port on the server: everything goes
over ssh.

## Steps

**Add the server**

1. In the Mac app, click **+** (**New project**) at the top of the **Projects** list and
   choose **Add a server…**. (Or open **Settings ▸ Servers** and click **Add a server**.)
2. Type the name you use with ssh: an alias from `~/.ssh/config`, or `user@host`, such as
   `agents@devbox.example.com`. Click **Connect**.
3. The first time, Agents shows the server's host key fingerprint. Check it matches the
   server: on the server, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it.
   Click **Trust and continue**.
4. Wait while the four steps tick: **Connect**, **Check the system**, **Set up** and
   **Find agent runtimes**. The last one lists the runtimes it found on the server.
   Click **Done**.

   The project list now has a heading for **THIS MAC** and one for the server, with a
   green dot while it is connected.

**Put a project on it**

1. Click **+** (**New project**), choose the server's name, then **Choose Folder…** or
   **Clone Git URL…**.
2. For a folder, **Choose a folder on devbox.example.com** opens on your home folder
   there. Type a path, such as `~/src/weather-app`, or click into folders, then click
   **Add as project**. A clone goes into your home folder on the server.

   The project appears under the server's heading. Start agents in it the usual way; the
   runtime menu offers the runtimes on the server.

**When the server is offline**

If the server stops answering (it is off, or your Mac lost the network), its heading says
**Offline** and the time, and its projects go grey. Agents already working there keep
working. An open conversation on it says, for example, **devbox.example.com is offline
since 10:42. Agents there keep working.**, with **Try now** to reconnect at once; until
then you cannot send a prompt. When it answers again, everything that happened while you
were away is there.

**Updates**

When you update the app, Agents updates its helper on each server by itself the next time
it connects. If an agent there is in the middle of a turn, the heading says **Update
waiting** and the update happens once the turn ends. There is nothing to do.

**Remove the server**

1. Open **Settings ▸ Servers**, find the server, and click **Remove…**.
2. To delete what Agents installed on the server too, tick **Also delete what Agents
   installed on devbox.example.com (~/.agents-server)**.
3. Click **Remove**. If agents are running there, the button says **Stop 1 and Remove**
   (or however many) and stops them first.

   Its projects leave the list. Your folders on the server are not touched.

Server projects are on the Mac only for now: iPhone and iPad show your Mac's projects,
not a server's.

## If it doesn't work

The sheet says what went wrong in one sentence. The common ones:

- **ssh can't find a host called "…"** Check the name, or add it to `~/.ssh/config`.
- **… refused the login. Is your key added to ssh-agent?** Run `ssh-add` in Terminal, and
  check `ssh devbox.example.com` logs in without a password.
- **Your key needs its passphrase.** Run `ssh-add` in Terminal, then **Try again**.
- **… Agents servers need Linux on x86-64 or ARM64.** The machine is not one Agents can
  use yet.
- **… doesn't allow forwarding a socket over ssh (AllowStreamLocalForwarding)** Set
  `AllowStreamLocalForwarding yes` in the server's `/etc/ssh/sshd_config` and restart
  sshd.
- **No agent runtime on …** under **Find agent runtimes**. Install a runtime on the
  server, sign in there, and click **Check again**.
- **…'s host key has changed since you last connected.** The server was rebuilt, or it is
  not the machine you think. Check with whoever runs it before connecting again.
