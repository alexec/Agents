---
diataxis: explanation
description: Why an agent in the app loses its runtime's own scheduler, report and document-store tools, what it keeps, and why your own setup is untouched.
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
- An agent the runtime addresses as a peer, by listing other agents and messaging them,
  is talking to agents the app cannot see, open or stop.
- A notification sent through the runtime's own channel never reaches your phone through
  the app, and is not in the conversation afterwards.
- A report written into a runtime's own document store is somewhere you never agreed to
  look.

Each of these works well on its own, and each one makes the app's picture of your work
wrong. So the app keeps its own picture right by leaving the agent only one way to do
each of these things: its own.

## What the app offers instead

The app gives each agent a small set of tools of its own. With them an agent can say how
its turn went, show you a file, suggest what you might say next, start, stop and park
other agents in the project, set up a workflow, take a turn on a shared resource, wait
for an event or publish one, and move into a worktree and back.
Everything these tools do shows up in the window and on your phone. The
[tools reference](../reference/agent-tools.md) lists them all.

Every runtime gets them. Copilot takes no MCP server it would have to start itself, so the
app runs its own tools for it and hands them to Copilot over a local http address that
only that agent can use.

## What is kept

Nothing the work itself needs is touched. Reading, searching, editing and writing files,
running commands, planning, and keeping a to-do list all stay. So does searching and
reading the web, where the runtime has it.

A runtime's own subagents and background commands stay too, and every runtime that has
them keeps them: starting one, listing them, reading what they printed, and stopping one.
Claude and Codex are the two that also tell the app about each one as it starts and ends, so
each appears in a list over the prompt, with **Stop** for a background command, and ends with
the turn that started it (see [Watch an agent's background work](../how-to/watch-background-work.md)).
The others use their own, and the app does not draw them. A runtime's own task list or
tracker stays for the same reason, so an agent can keep track of a job in the way its
runtime does that.

The runtime's tool for asking you a question also stays, on purpose. When an agent asks
you something that way, the app holds the question and shows it to you as a card, on the
Mac or on your phone, and waits for your answer. Taking that tool away would break the
one path an agent has to stop and ask you.

## How each runtime is scoped

The runtimes do not all offer the same way to take a tool away, so the app uses whatever
each one has.

- **Claude** takes a list of tools to deny for each session. It loses its schedulers,
  monitors and workflows, its push notifications, its own worktree tools, its report tools,
  and connectors that store documents. It keeps its subagents — starting, listing,
  messaging, reading and stopping them — and its tools for reading and stopping background
  work, which the app shows. Other connectors you have set up are left alone.
- **Grok** takes a list of the tools to keep for each session, plus a settings file the
  app writes inside its own folder. It loses its scheduler and its feedback tool, and keeps
  its subagents and its to-do list. Two of its tools, `workflow` and `monitor`, cannot be
  removed this way, so the agent is told in its briefing not to use them. Grok keeps its
  question tool too, but that tool has no way to reach the app, so Grok asks by ending its
  turn with the question as its summary, and waits for your reply. Grok also hides this
  app's own tools behind a search, so each Grok session is handed those tools by name, with
  their arguments, and told to call them directly.
- **Copilot** takes options when it starts. It keeps its subagents and loses its session
  store, and the app does not attach Copilot's built-in MCP servers to its sessions.
- **Cursor** has no way to take a tool away, and nothing left to take away: its subagent
  tool and its two goal tools are the app's business now too, so they are used. The first
  briefing points Cursor directly to the Agents app's MCP tools, whose schemas are available
  from the server.
- **Codex** takes feature switches in a variable set only for the sessions the app starts.
  It loses its sleep tool, its automations, its memories and its ChatGPT connectors. Its
  sub-agents and its goals are switched on, and the app shows the sub-agents as it does
  Claude's. Its question tool stays, and its questions reach you as a card.
- **Gemini** keeps its own subagents and task tracker, so it is sent no policy file at all.
- **Antigravity** takes a list of tools to deny for each session, and has nothing left in
  it, so it is sent no list; its question tool stays, and its questions reach you as a card.
- **OpenCode** takes its own settings in a variable set only for the sessions the app
  starts, laid over your `opencode.json` for that process. It keeps its subagent tool and
  its to-do list, as Claude's and Gemini's do. Sharing a conversation to OpenCode's website
  and self-update are switched off, as switches your own settings cannot turn back on. Left
  to itself OpenCode asks for nothing, so the app makes it ask before editing files, running
  commands and fetching web pages, unless you choose **Always-approve** for it in
  **Settings ▸ Agent Runtimes**. Its own question tool is off, so its questions come through
  the app's and reach you as a card.

Where a tool can only be named in the briefing, the agent is being asked, not stopped.
That is weaker, and the app says so rather than pretending otherwise.

## Nothing of yours changes

All of this applies only to sessions the app starts, and only for as long as they run.
The app does not read or write any configuration file in your home folder to do it, and
leaves nothing behind. Start the same runtime from Terminal a minute later and it has
every tool it always had, with your own settings, schedules and connectors.

## Related

- [Tools the app gives agents](../reference/agent-tools.md), for the full list.
- [Events](../reference/events.md), for what an agent can wait on and publish.
- [Sign a runtime in](../how-to/sign-a-runtime-in.md) and
  [Set up a workflow](../how-to/set-up-a-workflow.md).
- [Runtimes](../reference/runtimes.md), for what each runtime keeps and loses.
