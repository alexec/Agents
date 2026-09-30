---
diataxis: how-to
devices: [mac, iphone, ipad]
description: See the shells and subagents an agent runs in the background, read what they printed or did, and stop a shell.
---

# Watch an agent's background work

While it works, an agent can start a command that keeps running in the background, such
as a dev server or a long test run, or hand part of the work to a subagent of its own.
Each one is listed over the prompt while it runs, and you can read it, or stop a shell,
without stopping the agent.

Only Claude and Codex report what they start, so only their work shows in this list. When
another runtime starts a subagent of its own, the agent is running it and this list stays
empty; you can still read the agent's own account of it in the conversation.

## Before you start

- An agent on a runtime that tells the app about its background work: today Claude and
  Codex. The app goes by what the runtime says about itself, not by its name.

## Steps

**See what is running (Mac)**

1. Open the agent's conversation. While anything runs in the background, a block over the
   prompt is headed **In the background · 2** (or however many there are). The agent's
   row in the list says so too, for example **1 shell, 1 subagent in the background**.
2. Read a row. Each has the name the runtime gave it, what it is running or was asked to
   do, and how long it has been going (**0:37**). Hover over the name to see a shell's
   whole command.
3. Click **Output** to open what a shell has printed so far, or **Steps** to see what a
   subagent is doing, step by step, in the **Background** pane of the sidebar.

The conversation also says when each one started and ended, for example **Started “Run
the test suite” in the background** and **Shell “Run the test suite” finished**, with
**Steps** or **Output** beside it.

**Stop a shell**

Click **Stop** on its row. The row says **Stopping…** until the runtime has stopped it,
then **Stopped · 0:02**. Nothing else the agent is doing stops.

A subagent has no Stop: neither Claude nor Codex can stop one on its own. Its row says
**stops with the agent**. To stop it, stop the agent (Command-.).

**Look back at what ran**

Open the **Background** pane in the sidebar (**View ▸ Background**, Command-6). It lists
what the agent has had in the background lately, newest first, including what has ended,
each saying how: **Finished**, **Failed**, **Stopped** or **Ended with the turn**, with how
long it ran. Ended rows have no Stop, but **Output** and **Steps** still open. Until the
agent starts something, the pane says **Nothing in the background**.

**On iPhone and iPad**

On iPhone, a line over the prompt says **2 in the background ›**. Tap it for a sheet with
each one and **Stop** on shells; the sheet closes by itself when the last one ends. On
iPad, the block over the prompt is the same as the Mac's. **Steps** opens a subagent's
steps in a sheet of their own.

## Background work ends with the turn

A shell or subagent belongs to the turn that started it. When the runtime is let go at the
end of the turn, anything still running is marked **Ended with the turn**, and the
conversation says so once. Claude keeps its turn open until its subagents have finished,
so it is usually a shell that is ended this way.

## If it doesn't work

- **Nothing is listed, but the agent said it started something.** Its runtime does not
  tell the app about background work. Use the **Terminal** pane to see what is running in
  the agent's folder.
- **… can't be stopped on its own. Stop the agent to stop it.** The runtime refused the
  stop. The row goes back to running; stop the agent instead.
