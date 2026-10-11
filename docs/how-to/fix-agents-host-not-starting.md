---
diataxis: how-to
devices: [mac]
description: Find out why the control plane or this Mac's host won't start, fix the common cases with Repair, and send diagnostics with a report.
---

# Fix Agents Host when it won't start

Agents Host runs the control plane and this Mac's host as two login items, which macOS
starts and keeps running. When one of them can't start, Agents Host says why under
**This Mac**, and the Agents window names what is wrong rather than only that the host
isn't running.

## Before you start

- Agents Host, set up with **Run It Here** or **Join one elsewhere**. See
  [Set up Agents on this Mac](set-up-on-this-mac.md).

## Steps

1. Open Agents Host from the menu bar. Under **This Mac**, an orange line says what macOS
   and launchd say of the job that isn't running, for as long as it stays so.
2. Do what the line asks:
   - **Repair**, when the login item is out of date with this copy of Agents Host, or
     macOS couldn't start it. Repair registers both login items again from this copy,
     starts them, and gives this Mac's host a fresh code if it never joined. It then says
     what came of it: running, or the same reason again.
   - **Open Login Items**, when the line says Agents Host is waiting to be allowed. Turn on
     **Agents Host** under **Allow in the Background**, then come back.
3. If the line says Agents Host is also somewhere else (a copy in Downloads, say), move
   the other copy to the Bin and click **Repair**. Two copies share one set of login
   items, and the one that registered them last wins.

## When Repair doesn't fix it

Software that manages your Mac (an endpoint security or privilege manager) can stop a
login item from starting, and Repair can't get past it. Ask whoever manages your Mac to
allow Agents Host, then click **Repair** again.

To report it, click **Copy Diagnostics** at the bottom of Agents Host's window and paste
it into the report, or **Save Diagnostics…** to keep it as a file. It holds this copy's
version and place, both login items as macOS and launchd see them, what is listening on
8791 and 8792, and the end of both logs. Codes, keys and tokens are left out.

**Show Logs** selects both logs in Finder: `control.log` in
`~/Library/Application Support/Agents Control`, and `daemon.log` in this Mac's host's
folder.

From Terminal, the same report comes from
`"/Applications/Agents Host.app/Contents/MacOS/Agents Host" --diagnose`.

## After an update

macOS records which build of Agents Host registered its login items. After an update, or
a copy moved to another folder, it can refuse to start them until they are registered
again: that is the out-of-date line, and **Repair** is the fix.
