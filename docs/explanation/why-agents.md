---
diataxis: explanation
devices: [mac, iphone, ipad, server]
description: Why you would run your coding agents in Agents, alongside the editor and tools you already use, and when something else is the better choice.
---

# Why Agents

**Keep your editor and your coding agent. Agents is where you run several of them at once,
see which one needs you, let them work together and on their own, and answer them from
your phone.**

## It is not an editor

An editor with an agent in it is built for one task at a time: you ask, you watch, you
accept. Agents is built for five agents on five tasks while you are in a meeting. It has no
editor of its own. Open the same folder in yours whenever you like.

## It runs the agents you already have

Agents starts the coding tools already on your Mac, which are Claude, Grok, Copilot and
Cursor, each signed in with your own account and plan. It brings no model and no bill of
its own. You can choose a different runtime, model and permission mode for each agent.

They do not all do the same things; [Runtimes](../reference/runtimes.md) lists each.

## It shows which agent needs you

Every agent sits in one group: **Needs attention**, **Blocked**, **Working**,
**Complete**, **Stopped** or **Parked**. When an agent ends its turn, it says in one
sentence how it went. You can read the list and know what to open without reading any
conversation. See [Statuses and groups](../reference/statuses.md).

## You see the work, not just the chat

When an agent writes a document for you, such as a plan, a spec or a review, it opens
beside the conversation and fills in as the agent writes. Each change is marked, and the
page moves to it. You can type on the page yourself while it is being written, on the Mac,
the iPhone or the iPad. Diagrams arrive as pictures in the page, not as text to imagine.
See [Follow a live document](../how-to/follow-a-live-document.md).

When it changes code, the **Changes** pane lists every file it touched, with each edit
coloured down to the word. See [Read an agent's changes](../how-to/read-an-agents-changes.md).

## Agents that work together, and on their own

Agents take turns with what they share, wait for things to happen, and start when
something happens, without you.

Here is one afternoon. You asked Agents to watch your pull request. Its checks fail, and
a [workflow](../reference/workflows.md), a Markdown file kept in the repository, starts an
agent in that pull request's worktree. The agent needs the iOS simulator to reproduce the
failure, but another agent is using it. So it asks for a [lease](leases.md), gets in line
and ends its turn. It spends nothing while it waits, and it is started again when the
simulator is free.

It reproduces the failure, fixes it and pushes to the branch. Then it
[waits for the checks to pass](../how-to/wait-for-something.md). Its turn ends again, and
nothing polls. When the checks pass, it is woken and told so. It publishes
`custom.release_ready`, and a release agent that was waiting for that event wakes up and
starts on the release notes.

You were not asked for anything. The list shows each step as it happens.

Each part can be used on its own:

- **Pull requests, watched until they merge.** The project page lists your open pull
  requests on GitHub. With one click, an agent steps in whenever one needs something: it
  fixes a failing check, answers review comments and resolves conflicts, in the pull
  request's own worktree, and pushes as you. It never force-pushes.
  See [Have an agent watch a pull request](../how-to/watch-a-pull-request.md).
- **Leases.** Agents take turns with anything only one of them should use at a time: a
  simulator, a browser, the screen, or anything an agent names. The Mac's Resources page
  shows who holds what, and you can end a lease.
  See [Leases on shared resources](leases.md).
- **Events and waiting.** An agent can wait for a pull request's checks, another agent
  finishing, a branch moving, the Mac waking, you coming back, or an event another agent
  publishes. The Mac keeps a log of events, and the phone and iPad can read it.
  See [Events](../reference/events.md).
- **Workflows.** A workflow starts an agent on a schedule, such as every weekday at nine,
  or on an event, such as an agent finishing or a check failing. It is a file beside your
  code, reviewed like code.
  See [Set up a workflow](../how-to/set-up-a-workflow.md).
- **Agents that manage agents.** An agent can start up to three others, brief them, wait
  for them and stop them. Each can work in a [worktree](../how-to/start-in-a-worktree.md)
  of its own, so they never edit the same files.
  See [Tools the app gives agents](../reference/agent-tools.md).

Claude and Cursor may ask your permission before an agent uses some of these tools.

## They keep working without you

Your agents belong to a helper that runs in the background, not to the window. Close the
window or quit the app, and they carry on. They can still ask you questions, and the
questions wait. While a turn is in progress, the Mac does not go to sleep on its own. If
the Mac restarts, the agents that were working pick up where they stopped the next time
you open Agents. See [The window and the daemon](window-and-daemon.md).

On your iPhone or iPad you see the same list. You can read a conversation as it happens,
answer questions, send a prompt or a picture, start and stop agents, and open their files
and a terminal. When an agent needs you and you are away from the Mac, the device you used
last gets a notification. See [How the phone and iPad reach the Mac](phone-and-ipad.md).

## Your machines, one figure

The work happens on your Mac, or on a Linux server of your own over SSH. There is no
service of ours in between. See [Add a Linux server](../how-to/add-a-linux-server.md).

What every agent spends, on every runtime and server, adds up to one figure for today.
You can set a limit per agent and per day. See [Settings](../reference/settings.md).

## Compared with what you use now

**An agent in your editor** (Cursor, VS Code with Copilot, Windsurf, Zed).
You keep your editor. Agents adds many agents at once, live documents, watched pull
requests and everything above. You give up
editing and chatting in one window.

**An agent in a terminal** (Claude Code, Grok, Cursor's agent).
You keep the same tool, because Agents runs it, and adds a window over all your sessions.
In the conversations Agents starts, the tool's own scheduling, sub-agents and
notifications go through the app instead; from Terminal it is unchanged. See
[Why agents' own tools are taken away](scoped-tools.md).

**An agent in someone's cloud** (Copilot's coding agent, Codex in the cloud, Claude Code
on the web).
The work stays on your machines, with your own tools, files and simulators. You give up
having someone else's machine work while yours is off.

**Another app that runs several agents.**
Compare on the runtimes you already use, leases, events, workflows, the phone and servers.

## When something else is better

- **You want one assistant beside the file you are editing.** Your editor's agent is
  closer to hand.
- **You are not on a Mac.** Agents needs a Mac. Servers and phones hang off one.
- **You want to download and go.** Today Agents is built from source in Xcode.
- **You want to reach your agents from anywhere.** The phone and iPad reach the Mac on the
  same network. Notifications reach you anywhere, but answering needs that connection.
- **You use Copilot most.** Its conversations get none of the app's tools, so it cannot
  wait, lease or report how its turn went.
- **Your machine should be off while the work happens.** A cloud agent does that; Agents
  does not.

[Start here: your first agent](../tutorials/first-agent.md){ .md-button .md-button--primary }
