---
diataxis: explanation
description: Why your agents keep working when the window is closed, what Agents Host does, and what happens to your agents when the Mac restarts.
---

# The window and the host

On a Mac, Agents is two apps. The window, **Agents**, is the one you see, and it comes from
the App Store. The agents themselves belong to a host: on your Mac, that is **Agents
Host**, a separate download that runs in the background. This page explains why it is
built that way, and what it means for an agent that is working when you close the window
or restart the Mac.

## Who owns an agent

The host owns every agent. On your Mac, Agents Host runs a helper called the daemon, which
starts each agent's runtime, holds the conversation, writes down everything that happens,
and keeps each agent's record on disk. It is the only thing that writes those records. A
Linux server you add runs the same daemon, and owns the agents on it in the same way.

The window owns nothing. It connects to your control plane (see
[The control plane](control-plane.md)), shows you what your hosts hold, and passes on what
you type and click. Your iPhone and iPad do the same thing. Because nothing lives in the
window, closing it loses nothing, and a window on another Mac sees exactly what this one
does.

## The window starts nothing

The window runs in the App Store's sandbox. It starts no program of its own, keeps nothing
running in the background, and reads no file you did not hand it. Everything that needs a
real machine is asked of a host, through the control plane: starting an agent, a terminal,
reading and writing files, git, installing and signing in runtimes, and your shared skills
and instructions in `~/.agents`.

That is true of this Mac too. A project on this Mac is on this Mac's host, and the window
reaches its files the same way it reaches a server's. A folder you pick or drop for such a
project is passed to the host by its path; the window does not keep access to it.
**Reveal in Finder** and opening a file in another app are offered only for projects on this
Mac, and the host does them for the window.

If no control plane is set up, the window opens on one question, **Where should your agents
run?**, and offers **Set one up on this Mac** or **Connect to a control plane**. See
[Set up Agents on this Mac](../how-to/set-up-on-this-mac.md).

## What Agents Host does

Agents Host is signed by us and installed outside the App Store, because running agents
means starting programs, which an App Store app may not do. It lives in the menu bar and
has one window.

It registers two background jobs with macOS: this Mac's host, and, if you chose **Run the
control plane here**, a single copy of the control plane. macOS keeps both running whether
or not any window is open, and starts them again when you log in. They show under **Login
Items** in System Settings as Agents Host. Quitting Agents Host itself stops neither: your
agents keep running.

The host does not stop when it has nothing to do. It is always there for the next window
or phone that connects, and for a workflow's next scheduled run.

## Closing the window

Close the window, or quit Agents, while an agent is working. The host is still holding
that agent, so it carries on. It can still ask you a question, and the question waits on
the host for you. Any window or device connected to your control plane can answer it.

When you open Agents again, it connects to the control plane and picks up where it was,
without starting anything. A finished agent you haven't read is in its group, such as
**Done**, with its summary and an unread mark. Opening it clears the mark and nothing moves.

While any agent has a turn in flight, the host keeps the Mac from going to sleep because
it has been left alone. After the last turn stops, it stays awake for a while longer so
you can reply — an hour by default, or right away through eight hours in
**Settings ▸ General ▸ Sleep**. An agent waiting for your answer does not count as a turn
in flight, so that grace is when you get the time. Closing the lid, or choosing **Sleep**
yourself, still puts the Mac to sleep, and a turn in flight goes to sleep with it. At
20% battery or below the hold ends anyway.

If the control plane runs on this Mac, remember that while the Mac sleeps no window or
device can reach any of your agents, including those on servers.

## Restarting the Mac

Restarting the Mac, logging out, an update to Agents Host and a crash all end the host,
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
- [Stop, park and archive agents](../how-to/archive-park-stop.md).
- [Statuses and groups](../reference/statuses.md).
