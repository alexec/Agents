---
diataxis: how-to
devices: [mac, iphone, ipad, browser, server]
description: Back up a machine's agents and conversations to a folder on a schedule, keep a fixed number of backups, and restore one on a new machine.
---

# Back up and restore a machine

A machine is the only copy of its agents and their conversations. A backup copies them,
with the machine's usage and time history, into one file in a folder. It never copies a
sign-in, a key or any other secret. When you get a new machine, you can restore a backup
there: the agents come back archived, so you can read them, search them and bring them
back to the sidebar. An agent from another machine is shown, but never run, because its
conversation and its folder belong to the machine that made it.

## Where to find it

- **Mac:** Settings ▸ Mac ▸ **Backups**.
- **iPhone and iPad:** Settings ▸ **Backups**.
- **Browser:** Settings ▸ **Backups**.

All three show the backups of your Mac and change the same settings. Only the Mac can
choose the folder, because the folder is on the Mac's disk.

## Back up on a schedule

1. In **Back up**, choose **Every day** (the default), **Every week** or **Never**.
2. In **Keep**, choose how many backups of this machine to keep, from 1 to 10. The default
   is 3. When there are more, the oldest is deleted. Fewer takes effect at once.
3. On the Mac, click **Choose…** beside **Folder** to keep the backups on a second disk, or
   in a folder that your Mac syncs to another place. The default is the `backups` folder in
   the machine's data folder, which is on the same disk as what it backs up: it lets you
   undo a mistake, but does not survive the loss of the Mac.

The machine checks each hour whether a backup is due, starting ten minutes after it
starts. To make one now, click **Back Up Now**. It says **Backing Up…** until the backup is
made. If a backup fails, the section says why.

## Restore on a new machine

1. Put the old machine's backup folder where the new machine can read it: the same second
   disk or synced folder, or a copy of it.
2. On the new Mac, in Settings ▸ Mac ▸ **Backups**, click **Choose…** and select that
   folder. The list shows each backup with its date, the machine that made it, how many
   agents it holds and its size. A backup made by this machine says **This machine**.
3. Click **Restore…** beside a backup, then **Restore**.

It says, for example, **Restored 42 agents, archived.** An agent that is on this machine
already is left as it is, and counted as **was here already**, so you can restore the
same backup again safely. Nothing on the new machine is changed or deleted. The usage and
time history come back only to a machine that has none of its own.

A restored agent is kept for your **Archived agents** time from the day you restore it.

## In each shape

- **Single user** (Agents Host on your Mac): everything above. Choose a folder on a second
  disk or a synced folder, so the backups outlive the Mac.
- **Self-hosted** and **Hosted** (a control plane elsewhere, with servers as hosts): each
  server backs up every day to the `backups` folder of its own data folder, and keeps 3.
  To keep them somewhere else, set `"folder"` in `backup-settings.json` in the server's
  data folder to a full path, for example a mounted volume. Backing up a server to the
  control plane's store, and from its host page, is #1815.

## What is in a backup

Each backup is `<folder>/<root id>/<date>.tar.gz`, with a `.json` beside it that says what
it holds. The archive has, for each agent, `agent.json`, `transcript.jsonl`,
`turns.jsonl`, `app-tools.jsonl` and `said.json`, and the machine's
`usage-history.json` and `time-history.json`. A transcript line being written while the
backup is made is left out, never cut in half.

## Related

- [Archive and stop agents](archive-and-stop.md)
- [Move an existing set-up across](move-an-existing-set-up.md)
