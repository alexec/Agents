---
diataxis: explanation
description: Why your agents keep working when the window is closed, what runs in the background on your Mac, and what happens to your agents when the Mac restarts.
---

# The window and the host

On a Mac, Agents is one app, **Agents**. It is a download signed by us, not an App Store
app. It has the window that you see, and it runs this Mac's host in the background. The
agents belong to the host, not to the window. This page explains why it is built that
way, and what it means for an agent that is working when you close the window or restart
the Mac.

## Who owns an agent

The host owns every agent. On your Mac, the host is a helper called the daemon,
`agentsd`. It starts each agent's runtime, holds the conversation, writes down everything
that happens, and keeps each agent's record on disk. It is the only thing that writes
those records. A Linux server you add runs the same daemon, and owns the agents on it in
the same way.

The window owns nothing. It connects to your control plane (see
[The control plane](control-plane.md)), shows you what your hosts hold, and passes on what
you type and click. It reaches this Mac's own host directly, over a local socket, so it
still works with that host when the control plane is away. Your iPhone and iPad do the
same thing through the control plane. Because nothing lives in the window, closing it
loses nothing, and a window on another Mac sees exactly what this one does.

## The window starts nothing

The window starts no agent program of its own. This is a rule in the code: the daemon
owns the agents. Everything that needs a machine is asked of a host, through the control
plane or, for this Mac's host, directly: starting an agent, a terminal, reading and
writing files, git, installing and signing in runtimes, and your shared skills and
instructions in `~/.agents`.

That is true of this Mac too. A folder on this Mac is on this Mac's host, and the window
reaches its files the same way it reaches a server's. **Reveal in Finder** and opening a
file in another app are offered only for folders on this Mac.

## The first open

When you open Agents for the first time, it asks no question and needs no code. It makes
the control key, and registers two launch agents with macOS: a control plane on this Mac,
and this Mac's host, `agentsd`. It starts them, and joins this Mac's host to that control
plane. Then the window pairs itself with the control plane, so you copy and paste nothing.

Then the window opens on the empty session list. If a step fails, the window shows one
line with **Try Again** and **Show Details** in place of the list. When macOS asks you to approve the login
items, the line says so and has **Open Login Items**. See
[Set up Agents on this Mac](../how-to/set-up-on-this-mac.md).

Later, you can connect this Mac to another control plane, Hosted at agentloops.dev or one
that you run, in **Settings ▸ Control plane ▸ Connect to Another…**. See
[The control plane](control-plane.md#where-to-run-it).

## What runs in the background

macOS keeps the two launch agents running whether or not the window is open, and starts
them again when you log in. They show under **Login Items** in System Settings as Agents.
When the control plane runs somewhere else, only this Mac's host runs here.

Agents also has a menu bar item. It shows how many agents work and how many need you, and
has **Open Agents**, **Pair a Phone or iPad…**, **Open in Browser**, **Settings…** and
**Quit Agents**. Quitting Agents closes the window and the menu bar item. It stops neither
launch agent: your agents keep running. At login, macOS starts the launch agents and the
menu bar item, but not the window.

**Settings ▸ Machines ▸ This Mac** shows the state of both login items, with **Repair** and
**Open Login Items**, and has **Copy Diagnostics**, **Save Diagnostics…** and **Show Logs**.
The same diagnostics are in **Help ▸ Diagnostics**.

The host does not stop when it has nothing to do. It is always there for the next window
or phone that connects, and for a workflow's next scheduled run.

### Removing Agents

The two login items follow the app, not its path. If you move Agents to the Trash, they
keep running from the Trash, and after you empty it, macOS cannot start them but keeps
them in Login Items. So first use **Settings ▸ Machines ▸ This Mac ▸ Remove Agents from
This Mac…**. It stops both jobs and removes both login items. Then quit Agents and move it
to the Trash. Your sessions and folders stay on disk.

## Closing the window

Close the window, or quit Agents, while an agent is working. The host is still holding
that agent, so it carries on. It can still ask you a question, and the question waits on
the host for you. Any window or device connected to your control plane can answer it.

When you open the window again, it connects to the control plane and picks up where it was,
without starting anything. A finished agent you haven't read is in its group, such as
**Done**, with its summary and an unread mark. Opening it clears the mark and nothing moves.

While any agent has a turn in flight, the host keeps the Mac from going to sleep because
it has been left alone. After the last turn stops, it stays awake for a while longer so
you can reply — an hour by default, or right away through eight hours in
**Settings ▸ Machines ▸ This Mac ▸ Sleep**. An agent waiting for your answer does not count as a turn
in flight, so that grace is when you get the time. Closing the lid, or choosing **Sleep**
yourself, still puts the Mac to sleep, and a turn in flight goes to sleep with it. At
20% battery or below the hold ends anyway.

To let scheduled workflows and new issues run while you are away, turn on **Stay awake
on power, even with no agents** in the same place. While the Mac is on power, the host
then holds it awake with no agent working too. The display still sleeps and the screen
still locks. On battery the rules above apply. A MacBook with its lid closed and no
external display sleeps anyway, because a power assertion does not stop that.

If the control plane runs on this Mac, remember that while the Mac sleeps no window or
device can reach any of your agents, including those on servers.

## Restarting the Mac

Restarting the Mac, logging out, an update to Agents and a crash all end the host,
and every runtime it started ends with it. Nothing that was written down is lost: the
conversation, the cost, what you had queued, and what you had half typed into the prompt
are all still there.

macOS starts the host again when you log in, without you opening anything. The host reads
the records and finds the agents that were working when it ended. It marks them stopped,
adds a line to each conversation saying it stopped because the app did, and then picks
each one back up, most recently active first. The agent carries on the same conversation,
in the same folder, with the same runtime and settings, and is told that its turn was cut
off, so that it checks what it had actually finished instead of assuming its last step
worked.

A question that was waiting for your answer cannot survive this, because the runtime that
asked it has gone. The conversation says the question went unanswered, and the agent is
told so when it is picked up, so it can ask again. A notification for that question is
taken down from your devices.

A workflow on a schedule only runs while its host is running. A time that passed while it
was not is not made up later: the workflow says it missed that run, and waits for the next
one.

## What to expect

With the window closed, a working agent keeps working and finishes. With the Mac
restarted, a working agent stops, and carries on once you log in again. In both cases the
conversation and everything around it are still there.

## Related

- [The control plane](control-plane.md).
- [Stop and archive agents](../how-to/archive-and-stop.md).
- [Statuses and groups](../reference/statuses.md).
