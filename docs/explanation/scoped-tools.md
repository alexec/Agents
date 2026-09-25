---
diataxis: explanation
description: Why an agent in the app loses its runtime's own scheduler, subagents and report tools, what it keeps, and why your own setup is untouched.
---

# Why agents' own tools are taken away

Every runtime arrives with tools of its own for things the app also does: a way to
schedule work for later, a way to start another agent, a way to send you a notification,
somewhere to put a report. In the sessions the app starts, those tools are taken away,
and the app's own tools are offered instead. This page explains why, what is left, and
why none of it touches your own setup.

## Work the app cannot see

The app's job is to show you every agent and everything it is waiting on, in one place,
on your Mac and your phone. A runtime's own tools put work somewhere else.

- A schedule made with the runtime's own scheduler is a job with no row in the project.
  You would not see it, and you could not stop it from the app.
- A subagent started by the runtime is an agent you cannot see, open or stop, and whose
  cost is not in the total.
- A notification sent through the runtime's own channel never reaches your phone through
  the app, and is not in the conversation afterwards.
- A report written into a runtime's own document store is somewhere you never agreed to
  look.

Each of these works well on its own, and each one makes the app's picture of your work
wrong. So the app keeps its own picture right by leaving the agent only one way to do
each of these things: its own.

## What the app offers instead

The app gives each agent a small set of tools of its own. With them an agent can say how
its turn went, show you a file, suggest what you might say next, start and stop other
agents in the project, set up a workflow, take a turn on a shared resource, and work on a
pull request. Everything these tools do shows up in the window and on your phone. The
[Reference](../reference/index.md) lists them all.

Copilot is the exception today: its sessions have been seen without the app's tools, so a
Copilot agent may not be able to use them.

## What is kept

Nothing the work itself needs is touched. Reading, searching, editing and writing files,
running commands, planning, and keeping a to-do list all stay. So does searching and
reading the web, where the runtime has it.

The runtime's tool for asking you a question also stays, on purpose. When an agent asks
you something that way, the app holds the question and shows it to you as a card, on the
Mac or on your phone, and waits for your answer. Taking that tool away would break the
one path an agent has to stop and ask you.

## How each runtime is scoped

The runtimes do not all offer the same way to take a tool away, so the app uses whatever
each one has.

- **Claude** takes a list of tools to deny for each session. It loses its schedulers,
  monitors and workflows, its push notifications, its subagents, its report tools, and
  connectors that store documents. Other connectors you have set up are left alone.
- **Grok** takes a list of the tools to keep for each session, plus a settings file the
  app writes inside its own folder. It loses its scheduler, its feedback tool and its
  subagents. Two of its tools, `workflow` and `monitor`, cannot be removed this way, so the
  agent is told in its briefing not to use them. Grok keeps its question tool too, but
  that tool has no way to reach the app, so Grok asks by ending its turn with the question
  as its summary, and waits for your reply.
- **Copilot** takes options when it starts. It loses its subagents and its session store,
  and the app does not attach Copilot's built-in MCP servers to its sessions.
- **Cursor** has no way to take a tool away. Its three conflicting tools stay, and the
  agent's briefing names them and says what to use instead.

Where a tool can only be named in the briefing, the agent is being asked, not stopped.
That is weaker, and the app says so rather than pretending otherwise.

## Nothing of yours changes

All of this applies only to sessions the app starts, and only for as long as they run.
The app does not read or write any configuration file in your home folder to do it, and
leaves nothing behind. Start the same runtime from Terminal a minute later and it has
every tool it always had, with your own settings, schedules and connectors.

## Related

- [How-to guides](../how-to/index.md), for signing a runtime in and setting up workflows.
- [Reference](../reference/index.md), for the runtimes and the tools the app gives agents.
