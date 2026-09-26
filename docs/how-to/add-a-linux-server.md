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
- For Claude, nothing on the server: Agents installs what Claude needs there. You need a
  Claude token on this Mac instead; see [Give Claude a token](#give-claude-a-token) below.
  The server needs `curl` or `wget`, access to the internet, and a glibc Linux (glibc 2.28
  or newer, as on Debian 10, Ubuntu 20.04 or RHEL 8 and later).
- For Grok, Copilot or Cursor: install the runtime on the server yourself and sign in
  there, as that user. See [Runtimes](../reference/runtimes.md).

- If you built Agents yourself, build the server's helper once before building the app:
  `./scripts/build-linux-agentsd.sh`. It needs the swift.org toolchain and Static Linux
  SDK that match Xcode's Swift. Without it, adding a server says its system is not
  supported.

Agents copies its own helper, and Claude's tools when it installs them, into
`~/.agents-server` on the server. It opens no network port there: everything goes over
ssh.

## Steps

### Give Claude a token

Do this first if you will use Claude on the server. You can also do it later, when Agents
asks.

1. On this Mac, in Terminal, run `claude setup-token` and copy the token it prints. An API
   key from console.anthropic.com works too.
2. Open **Settings ▸ Servers**. Under **Signing in on servers**, paste it into **Paste a
   Claude token** and click **Save**. After a moment it says **Works**.

   The token is kept in this Mac's Keychain and is never written on a server. Agents lends
   it to a server only while an agent runs there. Agents on this Mac keep using this Mac's
   own sign-in.

### Add the server

1. In the Mac app, click **+** (**New project**) at the top of the **Projects** list and
   choose **Add a server…**. (Or open **Settings ▸ Servers** and click **Add a server**.)
2. Type the name you use with ssh: an alias from `~/.ssh/config`, or `user@host`, such as
   `agents@devbox.example.com`. Click **Connect**.
3. The first time, Agents shows the server's host key fingerprint. Check it matches the
   server: on the server, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints it.
   Click **Trust and continue**.
4. Wait while the steps tick: **Connect**, **Check the system**, **Set up**, then
   **Install Claude** if you gave Claude a token, then **Find agent runtimes**, which lists
   the runtimes on the server. Click **Done**.

   Without a token, the sheet says **Claude will be installed the first time you start it
   here.** If the server already has Claude signed in, **Install Claude** says **… has its
   own; Agents uses it**.

   The project list now has a heading for **THIS MAC** and one for the server, with a
   green dot while it is connected.

### Put a project on it

1. Click **+** (**New project**), choose the server's name, then **Choose Folder…** or
   **Clone Git URL…**.
2. For a folder, **Choose a folder on devbox.example.com** opens on your home folder
   there. Type a path, such as `~/src/weather-app`, or click into folders, then click
   **Add as project**. A clone goes into your home folder on the server.

   The project appears under the server's heading. Start agents in it the usual way; the
   runtime menu offers the runtimes on the server. Claude says **signs in with the token
   in Settings**, or **needs a token**.

   If you start Claude on a server with no token, a sheet says **Claude on … needs a
   token**. Paste one and the agent starts.

### Use the server's own sign-in instead

If Claude is already signed in on the server and you would rather Agents did not lend it
your token, open **Settings ▸ Servers**, find the server, and turn on **Use this server's
own sign-in only**.

### When the server is offline

If the server stops answering (it is off, or your Mac lost the network), its heading says
**Offline** and the time, and its projects go grey. Agents already working there keep
working. An open conversation on it says, for example, **devbox.example.com is offline
since 10:42. Agents there keep working.**, with **Try now** to reconnect at once; until
then you cannot send a prompt. When it answers again, everything that happened while you
were away is there.

### Updates

When you update the app, Agents updates its helper, and the Claude it installed, on each
server by itself the next time it connects. If an agent there is in the middle of a turn, the heading says **Update
waiting** and the update happens once the turn ends. There is nothing to do.

### When the server was rebuilt

If a server you added is rebuilt, Agents sees a new host key and says **… has a new
identity**. If you rebuilt it, click **This server was rebuilt**: Agents trusts the new
key and sets the server up again, installing Claude again if needed. If you did not
rebuild it, click **Cancel** and check with whoever runs it.

A project whose folder is no longer on the server says **Gone from …**. Remove it, or
put the folder back.

### Remove the server

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
- **No agent runtime on …** under **Find agent runtimes**. Give Claude a token in
  **Settings ▸ Servers**, or install another runtime on the server and sign in there, then
  click **Check again**.
- **… has neither curl nor wget to download Claude.** Install one of them on the server.
- **… can't reach the internet to download Claude.** The server needs to reach the
  internet once, to download Claude's tools.
- **Claude can't be installed on …: it uses musl.** Agents installs Claude only on glibc
  Linux. Install Claude there yourself, or use another server.
- **Claude refused the token in Settings. Replace it in Settings ▸ Servers.** The token
  was revoked or has expired. Make a new one with `claude setup-token` and click
  **Replace…**.
- **…'s host key has changed since you last connected.** The server was rebuilt, or it is
  not the machine you think. Check with whoever runs it, then see
  [When the server was rebuilt](#when-the-server-was-rebuilt).
- **… has a new identity.** See [When the server was rebuilt](#when-the-server-was-rebuilt).
