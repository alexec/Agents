---
diataxis: index
description: Short guides for one task each, for when you know the basics.
---

# How-to guides

One task each, for when you already know your way around the app and want to get
something particular done.

### Setting up

- [Set up Agents on this Mac](set-up-on-this-mac.md): install Agents Host, run your
  agents and the control plane here, and pair the window.
- [Connect a window or phone](connect-a-window-or-phone.md): pair another Mac, an iPhone,
  an iPad or a browser, change what it may do, and forget it.
- [Use Agents in a browser](use-agents-in-a-browser.md): open Agents in Safari or Chrome on
  the Mac that runs Agents Host, pair it once, and forget it.
- [Add a server](add-a-server.md): make a Linux server, or another Mac, a host of your
  control plane.
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md): on a
  machine you rent, at your own domain with a public certificate.
- [Run the control plane as several copies](run-several-copies.md): over one bucket,
  behind a load balancer, so it stays up when your Mac sleeps.
- [Move an existing set-up across](move-an-existing-set-up.md): bring the earlier app's
  agents, devices and servers to a control plane, once.

### Projects

- [Add a project](add-a-project.md): add a folder or clone a Git URL, and archive a
  project you are done with.
- [Start an agent in its own worktree](start-in-a-worktree.md): give an agent its own
  checkout and branch.
- [Give an agent more folders and MCP servers](give-an-agent-more-folders.md): let one
  agent work across two repositories, or reach a server only it needs.

### Agents

- [Choose a runtime, model and mode](choose-runtime-model-mode.md): what an agent runs
  on, and the meter for its context and cost.
- [Pick up a conversation started somewhere else](pick-up-a-conversation.md): carry on
  in Agents with one you began in Terminal, or delete one.
- [Answer a question or a permission request](answer-a-question.md): from the Mac, the
  iPhone or iPad, or a notification.
- [Send a prompt while an agent is working](send-while-an-agent-works.md): let it wait
  its turn, or put it into the running turn with **Send now**.
- [See what needs you from your Home screen](see-what-needs-you-from-your-home-screen.md):
  the number of sessions waiting on you, and a tap that opens one.
- [Watch an agent's background work](watch-background-work.md): the shells and
  subagents it runs in the background, their output, and **Stop**.
- [Use a shell in an agent's folder](use-a-shell.md): the Terminal pane, one shell to a
  tab.
- [Attach files and pictures to a prompt](attach-files.md): drag, paste, the paperclip,
  or an @ mention.
- [Read an agent's changes](read-an-agents-changes.md): the Changes pane, edits in the
  conversation, and the files pane.
- [Follow a live document](follow-a-live-document.md): watch a document take shape as an
  agent writes it, and type on it yourself.
- [Look at an HTML page an agent wrote](look-at-an-html-page.md): a report or wireframe as a
  page, with its stylesheet and pictures, and what it is not allowed to do.
- [Stop, park and archive agents](archive-park-stop.md): what each does, and what each
  keeps.
- [Sign a runtime in](sign-a-runtime-in.md): sign Claude Code, Codex, Copilot, Cursor, Grok
  or Antigravity in or out from the app, and give Gemini its key.
- [Share skills, instructions and servers with every agent](share-skills-across-agents.md):
  put them in `~/.agents` once, for every runtime and project.
- [Add a skill from a catalogue](add-a-skill-from-a-catalogue.md): search skills.sh, look
  before it goes in, and add it for yourself or to a project.
- [Add an MCP server from the registry](add-an-mcp-server-from-the-registry.md): search the
  MCP Registry, see what would run, and add it for yourself or to a project. Secrets stay
  in your own `secrets.env`.
- [Keep going when a runtime runs out](keep-going-when-a-runtime-runs-out.md): see which
  runtimes are out, and continue a chat's work in a new chat on another.
- [Limit what agents spend](limit-spending.md): the Spending page, and a limit per agent
  or per day.

### Servers

- [Add a server](add-a-server.md): make a Linux server a host of your control plane.

### Automation

- [Set up a workflow](set-up-a-workflow.md): start agents on a schedule, or when another
  agent finishes, stops or asks.
- [Have an agent wait for something](wait-for-something.md): checks passing, another
  agent finishing or the Mac waking, and agents telling each other.
