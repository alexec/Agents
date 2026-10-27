---
diataxis: how-to
devices: [mac, iphone, ipad, browser, server]
description: Back up a machine's agents and conversations to a folder or the control plane's store on a schedule, keep a fixed number of backups, and restore one on a new machine.
---

# Back up and restore a machine

A machine is the only copy of its agents and their conversations. A backup copies them,
with the machine's usage and time history, into one file in a folder. It never copies a
sign-in, a key or any other secret. A server backs up to the control plane's store instead,
so its backups outlive it. When you get a new machine, you can restore a backup
there: the agents come back archived, so you can read them, search them and bring them
back to the sidebar. An agent from another machine is shown, but never run, because its
conversation and its folder belong to the machine that made it.

Agent instructions, personas, skills, MCP server settings and plugin files sync across
your machines when they connect to the same control plane. This keeps the files available
on those machines. It is not a backup: it does not keep earlier versions or protect the
files if they are deleted everywhere. Keep a separate backup of configuration you need.

## Where to find it

- **Mac:** Settings ▸ Machines ▸ This Mac ▸ **Backups**.
- **iPhone and iPad:** Settings ▸ **Backups**.
- **Browser:** Settings ▸ **Backups**.

All three show the backups of your Mac and change the same settings. Only the Mac can
choose the folder, because the folder is on the Mac's disk.

A server's backups are on its own page:

- **Mac:** Settings ▸ Machines, the server's **⋯** menu ▸ **Backups…**.
- **iPhone and iPad:** Settings ▸ **Machines' Backups** ▸ the server.
- **Browser:** Settings ▸ **Machines' Backups** ▸ **Backups…** beside the server.

A server's page has the same settings, **Back Up Now** and **Restore…**, sent to that
server. A server is listed while it is online.

## Back up on a schedule

1. In **Back up**, choose **Every day** (the default), **Every week** or **Never**.
2. In **Keep**, choose how many backups of this machine to keep, from 1 to 10. The default
   is 3. When there are more, the oldest is deleted. Fewer takes effect at once.
3. On the Mac, click **Choose…** beside **Folder** to keep the backups on a second disk, or
   in a folder that your Mac syncs to another place. The default is the `backups` folder in
   the machine's data folder, which is on the same disk as what it backs up: it lets you
   undo a mistake, but does not survive the loss of the Mac. While the folder is on that
   disk, and is not a synced folder (iCloud Drive, or one in `~/Library/CloudStorage`), the
   section says so on all three, until you choose another.

The machine checks each hour whether a backup is due, starting ten minutes after it
starts. To make one now, click **Back Up Now**. It says **Backing Up…** until the backup is
made. If a backup fails, the section says why.

## Choose where backups go

A machine on a control plane shows **Back up to**: **A folder** or **The control plane**.

- **A folder** is the default on a Mac.
- **The control plane** is the default on a server. Each backup goes to the control plane's
  store (its folder or bucket) in parts of 8 MiB, under your account, and the copy on the
  server is deleted once it is sent. The store keeps the newest **Keep** backups of each
  machine. Each part is sealed with a key made from the control plane's key, so the store
  never holds a conversation in clear.

## Restore on a new machine

1. Put the old machine's backup folder where the new machine can read it: the same second
   disk or synced folder, or a copy of it.
2. On the new Mac, in Settings ▸ Machines ▸ This Mac ▸ **Backups**, click **Choose…** and select that
   folder. The list shows each backup with its date, the machine that made it, how many
   agents it holds and its size. A backup made by this machine says **This machine**.
3. Click **Restore…** beside a backup, then **Restore**.

It says, for example, **Restored 42 agents, archived.** An agent that is on this machine
already is left as it is, and counted as **was here already**, so you can restore the
same backup again safely: then it says **Nothing to restore: 42 agents were here
already.** Nothing on the new machine is changed or deleted. The usage and
time history come back only to a machine that has none of its own.

A restored agent is kept for your **Archived agents** time from the day you restore it.

## In each shape

- **Single user** (Agents Host on your Mac): everything above. Choose a folder on a second
  disk or a synced folder, so the backups outlive the Mac.
- **Self-hosted** and **Hosted** (a control plane elsewhere, with servers as hosts): each
  server backs up every day to the control plane's store, and the store keeps the newest 3
  of each server. Change that on the server's page. A new server of yours lists every
  backup of your servers in the store, also the backups of a server that was deleted, and
  restores one as above: open the new server's page and click **Restore…**.
- **A workspace that is deleted** (a server that a provider made): when it is online, it
  backs up first, and is deleted only when the backup is made. Its row says **Backing up
  to delete**. If the backup fails, the server is not deleted, and its row says why. A
  workspace that is offline is deleted at once; the backups it made are kept.
- The store keeps the backups of a server that was removed for 90 days after its newest
  one, so you have time to restore them on a new server. Parts that a backup cut off left
  behind are deleted after a day.

## What is in a backup

Each backup is `<folder>/<root id>/<date>.tar.gz`, with a `.json` beside it that says what
it holds. In the control plane's store, it is
`v1/backups/<owner>/<host>/<date>/<part>.part` (sealed), with `<date>.json` beside it. The archive has, for each agent, `agent.json`, `transcript.jsonl`,
`turns.jsonl`, `app-tools.jsonl` and `said.json`, and the machine's
`usage-history.json` and `time-history.json`. A transcript line being written while the
backup is made is left out, never cut in half.

## Related

- [Back up and restore a control plane](back-up-a-control-plane.md): its records, key and
  certificate, which these backups do not hold
- [Archive and stop agents](archive-and-stop.md)
- [Move an existing set-up across](move-an-existing-set-up.md)
# Agent configuration sync is not a backup

Agent instructions, personas, skills, MCP server settings and plugin files sync across
your machines when they connect to the same control plane. This keeps the files available
on those machines. It is not a backup: it does not keep earlier versions or protect the
files if they are deleted everywhere. Keep a separate backup of configuration you need.
