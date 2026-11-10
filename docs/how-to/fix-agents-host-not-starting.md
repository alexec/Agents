---
diataxis: how-to
devices: [mac]
description: Find out why the control plane or this Mac's host won't start, fix the common cases with Repair, and send diagnostics with a report.
---

# Fix Agents when it won't start

Agents runs the control plane and this Mac's host (`agentsd`) as two login items, which
macOS starts and keeps running. When one of them cannot start, Agents says why, and the
window names what is wrong. It does not say only that the host isn't running.

## Before you start

- Agents on this Mac. See [Set up Agents on this Mac](set-up-on-this-mac.md).

## The first time you open Agents

If a step of the first open fails, the window shows one line that says what went wrong,
with **Try Again** and **Show Details**. **Show Details** says more, and has **Show Logs**.

- When macOS waits for you to allow Agents, the line says so and shows
  **Open Login Items**. Click it, turn on **Agents** under **Allow in the Background**, and
  come back. Agents sees the change and continues by itself.
- For other failures, read the details, fix the cause, and click **Try Again**.

## Steps

1. In Agents, open **Settings ▸ Machines ▸ This Mac**. At the top, the **Agents** section
   shows whether both login items run. While a job does not run, an orange line says what
   macOS and launchd say about it.
2. Do what the line asks:
   - **Repair**, when the login item is out of date with this copy of Agents, or macOS
     could not start it. Repair registers both login items again from this copy, starts
     them, and gives this Mac's host a new code if it never joined. Then it says the
     result: running, or the same reason again.
   - **Open Login Items**, when the line says that Agents waits for you to allow it. Turn
     on **Agents** under **Allow in the Background**, then come back.
3. If the line says that Agents is also in another place (a copy in Downloads, for
   example), move the other copy to the Trash and click **Repair**. Two copies share one
   set of login items, and the copy that registered them last wins.

If this Mac's host runs but cannot join the control plane, the same section says
**Couldn't join the control plane:** and why, with **Try Again**.

## When Repair doesn't fix it

Software that manages your Mac (an endpoint security or privilege manager) can stop a
login item from starting, and Repair cannot get past it. Ask the person who manages your
Mac to allow Agents, then click **Repair** again.

To report it, choose **Help ▸ Diagnostics ▸ Copy Diagnostics** and paste the result into
the report, or **Save Diagnostics…** to keep it as a file. The same buttons are in
**Settings ▸ Machines ▸ This Mac**. The report holds this copy's version and place, both
login items as macOS and launchd see them, what listens on 8791 and 8792, and the end of
both logs. It leaves out codes, keys and tokens.

**Show Logs** selects both logs in Finder: `control.log` and `daemon.log`, both in
`~/Library/Logs/Agents`.

From Terminal, the same report comes from
`"$HOME/Applications/Agents.app/Contents/MacOS/Agents Host" --diagnose`. The program in the
app keeps its old name, `Agents Host`.

## After an update

macOS records which build of Agents registered its login items. After an update, or after
you move a copy to another folder, macOS can refuse to start them until they are
registered again. The out-of-date line then shows, and **Repair** is the fix.

## Remove Agents

To remove Agents from this Mac, click **Remove Agents from This Mac…** in
**Settings ▸ Machines ▸ This Mac**, then **Remove**. It stops both login items and removes
them. Then quit Agents and move it to the Trash. Your sessions and the control plane's
records stay on disk until you delete them.

If you move Agents to the Trash first, its login items stay registered. They run from the
Trash until you empty it, and then macOS cannot start them. Turn them off in
**System Settings ▸ General ▸ Login Items**.
