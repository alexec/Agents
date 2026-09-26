---
diataxis: explanation
description: Why your agents keep working when the window is closed, and what happens to them when the Mac restarts.
---

# The window and the daemon

Agents is two programs. The window is the one you see. The agents themselves belong to a
second program, a helper called the daemon, which runs in the background on your Mac. This
page explains why it is built that way, and what it means for an agent that is working
when you close the window or restart the Mac.

## Who owns an agent

The daemon owns every agent. It starts each agent's runtime, holds the conversation,
writes down everything that happens, and keeps each agent's record on disk. It is the only
thing that writes those records.

The window owns nothing. It connects to the daemon, shows you what the daemon holds, and
passes on what you type and click. Your iPhone and iPad do the same thing from further
away. Because nothing lives in the window, closing it loses nothing.

The window starts the daemon when you open Agents, if it is not already running. There is
no login item and nothing extra to install: the daemon lives inside the app.

## When the daemon stops by itself

The daemon exits on its own once it has nothing to do and nobody is looking. That means
no window is connected and it is holding no work. Work includes:

- an agent that is working or starting up,
- an agent waiting for you to answer a question,
- a message you sent that has not reached its agent yet,
- a command still running in one of the app's terminals,
- a project still being cloned,
- an agent waiting in line for a shared resource (see
  [Leases on shared resources](leases.md)).

It waits a few seconds first, so quitting Agents and opening it again straight away finds
the same daemon. An agent that has finished, stopped or been archived is not work: its
record stays on disk, and the next daemon reads it.

## Closing the window

Close the window, or quit Agents, while an agent is working. The daemon is still holding
that agent, so it carries on. It can still ask you a question, and the question waits for
you. If you have set up your iPhone, the question reaches it there.

When the agent finishes and nothing else is going on, the daemon exits. When you open
Agents again, a new daemon starts, reads the records, and the agent is under **Complete**
with its summary, as if you had watched it finish.

While any agent has a turn in flight, the daemon keeps the Mac from going to sleep because
it has been left alone. It lets go as soon as no turn is in flight. An agent waiting for
your answer does not keep the Mac awake. Closing the lid, or choosing **Sleep** yourself,
still puts the Mac to sleep, and a turn in flight goes to sleep with it.

## Restarting the Mac

Restarting the Mac, logging out, an app update and a crash all end the daemon, and every
runtime it started ends with it. Nothing that was written down is lost: the conversation,
the cost, what you had queued, and what you had half typed into the prompt are all still
there.

Nothing starts the daemon again until you open Agents. When you do, the new daemon reads
the records and finds the agents that were working when the last one ended. It marks them
stopped, adds a line to each conversation saying it stopped because the app did, and then
picks each one back up, most recently active first. The agent carries on the same
conversation, in the same folder, with the same runtime and settings, and is told that its
turn was cut off, so that it checks what it had actually finished instead of assuming its
last step worked.

A question that was waiting for your answer cannot survive this, because the runtime that
asked it has gone. The conversation says the question went unanswered, and the agent is
told so when it is picked up, so it can ask again. A notification for that question is
taken down from your devices.

A workflow on a schedule only runs while the daemon is running. A time that passed while it
was not is not made up later: the workflow says it missed that run, and waits for the next
one.

## What to expect

With the window closed, a working agent keeps working and finishes. With the Mac
restarted, a working agent stops, and carries on when you next open Agents. In both cases
the conversation and everything around it are still there.

## Related

- [How-to guides](../how-to/index.md), for starting, stopping and archiving agents.
- [Reference](../reference/index.md), for what each status and group means.
