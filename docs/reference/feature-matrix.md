---
diataxis: reference
description: Which apps for running several coding agents have which features, Agents included, as found by the weekly competitor check.
---

# Feature matrix of coding-agent apps

This page lists every app the weekly competitor check has found that runs several coding
agents at once, against the full set of features found across them. Agents is the first
row. The other apps follow in alphabetical order.

- ● the app has it, in full.
- ◐ it has part of it: only by hand, only in an alpha, beta or by request, only on some
  platforms or runtimes, or only through someone else's add-on.
- ○ it does not.
- ?⃝ unknown: the app's docs, changelog, README and code did not say either way.

The matrix was filled in on 2026-10-12 from each app's own docs, changelog, README,
releases and, where open, source. Every app is held to the same bar, Agents included: a ●
needs the whole feature, documented by the app itself, and a ○ needs evidence, such as an
app that ships for macOS alone having no Android app. Keep it current when the weekly
competitor check finds something new; its reports in `~/.agents/reviews/competitors/`
give the sources. Apps change every week, so check a row against the app before relying
on it.

## Where Agents falls short

Agents' ◐ cells, and why:

- **Runs with the computer off:** agents on servers keep working, but nothing can reach
  them while the Mac that runs the control plane sleeps. See
  [The control plane](../explanation/control-plane.md).
- **Sandboxed tools:** the app passes each runtime's own command sandbox through, and adds
  none of its own. See [Runtimes](runtimes.md).
- **End-to-end encrypted relay:** built but not switched on. `agents-relay` seals each
  message so only the control plane and that one device can read it, and carries it
  through the person's own iCloud, but Agents Host does not start it yet, so its
  **Relay for my devices** switch is greyed (#809). Until then a phone away from home
  reaches agents only when the control plane has a public address.
- **Notifications:** the Mac gets them. The relay that takes them to the iPhone and iPad
  is not switched on yet (#809), and the web page gets none. See
  [Phone and iPad](../explanation/phone-and-ipad.md).
- **Pull requests:** the ci board lists them. Nothing can be created, reviewed or merged in
  the app.
- **Browser or preview:** the Browser pane is on the Mac only.
- **Starts agents from issues:** only through a workflow on the `ci` server's
  `issue.opened`, and only for GitHub.
- **Spending limits:** only for runtimes that report a price. See
  [Limit spending](../how-to/limit-spending.md).
- **Switch when allowance runs out:** done by hand: a new chat on another runtime
  continues the first. See
  [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md).
- **A second agent reviews:** only as a workflow, such as the weekly review-and-fix.
- **Rich cards in replies:** question and plan cards, ui:// views from MCP servers and
  live HTML pages, but an agent cannot put a chart or table card in a reply.

Agents has none of these at all:

- Android app (#810), Windows or Linux desktop (#811).
- Sessions side by side, sessions as a tree, a task board.
- A browser the agent drives, simulator panes, language servers.
- Plugins of its own, several accounts per runtime, teams.
- Trackers and git hosts beyond GitHub.

## What each feature means


**Running agents**

- **Several agents at once:** Several agent sessions run at the same time.
- **A git worktree per agent:** Each agent can work in its own git worktree and branch, made by the app.
- **Several runtimes:** It runs more than one vendor's agent, such as Claude Code and Codex.
- **ACP:** It speaks the Agent Client Protocol.
- **Runs with the computer off:** Agents run on a remote or cloud machine, and can be reached, while the person's own computer is off.
- **Sandboxed tools:** Agent tools run under a file or network policy, or in a container, that the app sets up.

**Where you reach it**

- **Windows or Linux desktop:** A desktop app for Windows or Linux, not only a terminal program.
- **iPhone or iPad app:** A native app for iPhone or iPad.
- **Android app:** A native app for Android.
- **Web client:** Agent sessions can be used from a browser.
- **End-to-end encrypted relay:** A phone or browser away from home reaches the agents through a relay that cannot read them.
- **Notifications:** Push or system notifications when an agent needs the person or finishes.

**Following and answering**

- **Shows who needs you:** A status shows which agent is waiting on the person.
- **Sessions side by side:** Several sessions are visible at once, in a split, grid or separate windows.
- **Sessions as a tree:** Sessions are shown under the session that started them.
- **Send while it works:** A message can be sent, queued or used to steer while the agent is working.
- **Voice or dictation:** Prompts can be spoken.
- **Rich cards in replies:** Agent replies can hold interactive cards, tables or charts, beyond Markdown.

**Reviewing work**

- **Diff review:** The agent's changes can be reviewed as a diff in the app.
- **Pull requests:** Pull requests can be created, reviewed and merged in the app.
- **Git hosts beyond GitHub:** Pull requests and checks work with GitLab, Bitbucket or others too.
- **CI checks:** CI status is shown or watched.
- **A second agent reviews:** Another agent reviewing the first one's work is a feature of the app.

**Tools in the app**

- **Terminal:** A terminal is built in.
- **Browser or preview:** A browser or web preview is built in.
- **A browser the agent drives:** The agent itself can click and read in the built-in browser.
- **Simulator or emulator panes:** An iOS Simulator or Android Emulator shows in the app.
- **File editor:** Files can be edited in the app.
- **Language servers in the editor:** The editor has completion and diagnostics from language servers.

**Tasks and automation**

- **Task board:** A task list or kanban board is built in.
- **Starts agents from issues:** An issue starts an agent, or an agent is started from an issue in one step.
- **Trackers beyond GitHub:** Linear, Jira or other trackers are connected in the app.
- **Scheduled or triggered runs:** Agents start on a schedule or on an event.
- **Agents start agents:** An agent can start and manage other agents.
- **The app's own tools for agents:** The app gives its agents tools of its own, over MCP or a CLI.

**Extensions, accounts and cost**

- **MCP or skills catalogue:** A catalogue or marketplace to add MCP servers or skills from.
- **Plugins:** The app has plugins or extensions of its own.
- **Usage or cost:** Usage, allowance or cost is shown.
- **Spending limits:** Spending can be capped.
- **Several accounts per runtime:** More than one account for the same runtime, such as two Claude logins.
- **Switch when allowance runs out:** It moves to another runtime or account, by itself, when one runs out.

**Organising**

- **Labels or tags:** Sessions or tasks can be labelled.
- **Pins:** Sessions or tasks can be pinned.
- **Archive:** Sessions can be archived.
- **Teams:** Several people can use it together.
- **Open source:** The app's source is under an open-source licence. Source-available counts as ○.
- **Self-hosted:** It runs entirely on the person's own machines and servers.

## Running agents

| App | Several agents at once | A git worktree per agent | Several runtimes | ACP | Runs with the computer off | Sandboxed tools |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ● | ● | ● | ◐ | ◐ |
| Agentastic | ● | ● | ● | ● | ● | ● |
| Atelier (was Acepe) | ● | ?⃝ | ● | ● | ?⃝ | ?⃝ |
| Claude Code | ● | ● | ○ | ?⃝ | ● | ● |
| Claude Squad | ● | ● | ● | ○ | ?⃝ | ?⃝ |
| CodeAgentSwarm | ● | ● | ● | ◐ | ○ | ◐ |
| Codeg | ● | ● | ● | ● | ● | ◐ |
| Conductor | ● | ● | ● | ?⃝ | ● | ◐ |
| Cursor | ● | ● | ○ | ● | ● | ● |
| DockTerm | ● | ?⃝ | ○ | ?⃝ | ○ | ?⃝ |
| Emdash | ● | ● | ● | ● | ● | ?⃝ |
| GitHub Copilot | ● | ● | ● | ◐ | ● | ● |
| Happy | ● | ● | ● | ◐ | ● | ● |
| Helicon | ● | ◐ | ○ | ○ | ● | ?⃝ |
| Maestro | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ |
| Nimbalyst | ● | ● | ● | ◐ | ◐ | ● |
| Nuphos | ● | ?⃝ | ● | ● | ● | ● |
| OpenAI Codex | ● | ● | ○ | ?⃝ | ● | ● |
| Parallel Code | ● | ● | ● | ?⃝ | ○ | ● |
| Paseo | ● | ● | ● | ● | ● | ◐ |
| Pragma | ● | ● | ● | ◐ | ● | ?⃝ |
| ReevesAgents | ● | ○ | ● | ?⃝ | ?⃝ | ○ |
| Roamgate | ● | ● | ● | ?⃝ | ● | ?⃝ |
| Rove | ● | ● | ● | ?⃝ | ● | ?⃝ |
| Sculptor | ● | ● | ● | ?⃝ | ?⃝ | ◐ |
| Superset | ● | ● | ● | ?⃝ | ● | ◐ |
| T3 Code | ● | ● | ● | ● | ● | ?⃝ |
| Threadlines | ● | ● | ● | ● | ● | ?⃝ |
| tuios | ● | ● | ● | ● | ● | ○ |
| Vibe Kanban | ● | ● | ● | ?⃝ | ● | ?⃝ |
| VibeiDE | ● | ● | ● | ?⃝ | ○ | ?⃝ |
| Warp | ● | ● | ● | ?⃝ | ● | ● |

## Where you reach it

| App | Windows or Linux desktop | iPhone or iPad app | Android app | Web client | End-to-end encrypted relay | Notifications |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ○ | ● | ○ | ● | ◐ | ◐ |
| Agentastic | ○ | ◐ | ○ | ○ | ● | ● |
| Atelier (was Acepe) | ◐ | ○ | ○ | ○ | ○ | ?⃝ |
| Claude Code | ● | ● | ● | ● | ○ | ● |
| Claude Squad | ○ | ○ | ○ | ○ | ○ | ○ |
| CodeAgentSwarm | ● | ◐ | ◐ | ◐ | ?⃝ | ● |
| Codeg | ● | ◐ | ◐ | ● | ○ | ● |
| Conductor | ○ | ◐ | ?⃝ | ?⃝ | ○ | ● |
| Cursor | ● | ● | ○ | ● | ○ | ● |
| DockTerm | ● | ○ | ○ | ○ | ○ | ● |
| Emdash | ● | ○ | ○ | ○ | ○ | ● |
| GitHub Copilot | ● | ● | ● | ● | ?⃝ | ● |
| Happy | ● | ● | ● | ● | ● | ● |
| Helicon | ● | ○ | ○ | ● | ○ | ?⃝ |
| Maestro | ● | ○ | ○ | ● | ○ | ● |
| Nimbalyst | ● | ● | ◐ | ◐ | ● | ● |
| Nuphos | ● | ● | ◐ | ?⃝ | ○ | ?⃝ |
| OpenAI Codex | ● | ● | ● | ● | ?⃝ | ● |
| Parallel Code | ● | ○ | ● | ● | ◐ | ● |
| Paseo | ● | ● | ● | ● | ● | ● |
| Pragma | ● | ● | ● | ● | ○ | ● |
| ReevesAgents | ○ | ○ | ○ | ● | ○ | ○ |
| Roamgate | ◐ | ○ | ○ | ● | ◐ | ● |
| Rove | ○ | ◐ | ◐ | ○ | ○ | ● |
| Sculptor | ● | ○ | ○ | ?⃝ | ○ | ● |
| Superset | ◐ | ● | ○ | ○ | ?⃝ | ● |
| T3 Code | ● | ● | ● | ● | ◐ | ● |
| Threadlines | ● | ○ | ○ | ● | ● | ?⃝ |
| tuios | ○ | ○ | ○ | ● | ○ | ● |
| Vibe Kanban | ● | ○ | ○ | ● | ?⃝ | ● |
| VibeiDE | ● | ○ | ○ | ● | ● | ?⃝ |
| Warp | ● | ○ | ○ | ● | ◐ | ● |

## Following and answering

| App | Shows who needs you | Sessions side by side | Sessions as a tree | Send while it works | Voice or dictation | Rich cards in replies |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ○ | ○ | ● | ● | ◐ |
| Agentastic | ● | ● | ● | ● | ◐ | ● |
| Atelier (was Acepe) | ● | ● | ◐ | ● | ● | ○ |
| Claude Code | ● | ● | ● | ● | ● | ◐ |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ?⃝ | ○ |
| CodeAgentSwarm | ● | ● | ◐ | ?⃝ | ?⃝ | ?⃝ |
| Codeg | ● | ● | ◐ | ● | ?⃝ | ● |
| Conductor | ● | ?⃝ | ?⃝ | ● | ?⃝ | ◐ |
| Cursor | ● | ● | ?⃝ | ● | ● | ● |
| DockTerm | ● | ● | ◐ | ?⃝ | ● | ?⃝ |
| Emdash | ● | ● | ?⃝ | ● | ◐ | ◐ |
| GitHub Copilot | ● | ● | ● | ● | ● | ● |
| Happy | ● | ?⃝ | ◐ | ● | ● | ● |
| Helicon | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ |
| Maestro | ● | ● | ◐ | ● | ?⃝ | ◐ |
| Nimbalyst | ● | ?⃝ | ● | ● | ● | ● |
| Nuphos | ?⃝ | ● | ● | ● | ◐ | ● |
| OpenAI Codex | ● | ● | ◐ | ● | ● | ◐ |
| Parallel Code | ● | ● | ● | ● | ◐ | ○ |
| Paseo | ● | ● | ◐ | ● | ● | ◐ |
| Pragma | ● | ● | ◐ | ● | ?⃝ | ◐ |
| ReevesAgents | ?⃝ | ● | ?⃝ | ● | ○ | ○ |
| Roamgate | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Rove | ● | ?⃝ | ?⃝ | ● | ?⃝ | ○ |
| Sculptor | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ◐ |
| Superset | ● | ● | ◐ | ● | ?⃝ | ◐ |
| T3 Code | ● | ?⃝ | ◐ | ● | ◐ | ● |
| Threadlines | ● | ?⃝ | ● | ● | ● | ?⃝ |
| tuios | ● | ● | ◐ | ● | ?⃝ | ○ |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ |
| VibeiDE | ?⃝ | ● | ?⃝ | ?⃝ | ● | ?⃝ |
| Warp | ● | ● | ◐ | ● | ● | ● |

## Reviewing work

| App | Diff review | Pull requests | Git hosts beyond GitHub | CI checks | A second agent reviews |
|---|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ◐ | ○ | ● | ◐ |
| Agentastic | ● | ● | ◐ | ● | ● |
| Atelier (was Acepe) | ● | ● | ○ | ● | ?⃝ |
| Claude Code | ● | ● | ◐ | ● | ◐ |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ○ |
| CodeAgentSwarm | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Codeg | ● | ● | ● | ● | ◐ |
| Conductor | ● | ● | ?⃝ | ● | ● |
| Cursor | ● | ● | ● | ● | ● |
| DockTerm | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Emdash | ● | ● | ○ | ● | ?⃝ |
| GitHub Copilot | ● | ● | ● | ● | ● |
| Happy | ● | ?⃝ | ?⃝ | ?⃝ | ◐ |
| Helicon | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Maestro | ● | ● | ?⃝ | ?⃝ | ◐ |
| Nimbalyst | ● | ● | ○ | ● | ?⃝ |
| Nuphos | ◐ | ● | ● | ● | ?⃝ |
| OpenAI Codex | ● | ● | ◐ | ?⃝ | ● |
| Parallel Code | ● | ● | ?⃝ | ● | ?⃝ |
| Paseo | ● | ● | ● | ● | ◐ |
| Pragma | ● | ● | ?⃝ | ● | ?⃝ |
| ReevesAgents | ○ | ○ | ?⃝ | ○ | ?⃝ |
| Roamgate | ● | ● | ● | ● | ?⃝ |
| Rove | ● | ● | ?⃝ | ● | ?⃝ |
| Sculptor | ● | ● | ?⃝ | ● | ● |
| Superset | ● | ● | ○ | ● | ◐ |
| T3 Code | ● | ● | ● | ● | ?⃝ |
| Threadlines | ● | ● | ● | ● | ● |
| tuios | ● | ● | ?⃝ | ● | ?⃝ |
| Vibe Kanban | ● | ● | ● | ?⃝ | ?⃝ |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ● |
| Warp | ● | ?⃝ | ● | ?⃝ | ● |

## Tools in the app

| App | Terminal | Browser or preview | A browser the agent drives | Simulator or emulator panes | File editor | Language servers in the editor |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ◐ | ○ | ○ | ● | ○ |
| Agentastic | ● | ● | ● | ?⃝ | ● | ● |
| Atelier (was Acepe) | ?⃝ | ● | ● | ?⃝ | ● | ● |
| Claude Code | ● | ● | ● | ◐ | ● | ?⃝ |
| Claude Squad | ● | ?⃝ | ○ | ○ | ?⃝ | ○ |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ○ | ○ |
| Codeg | ● | ● | ● | ?⃝ | ● | ?⃝ |
| Conductor | ● | ◐ | ?⃝ | ?⃝ | ● | ?⃝ |
| Cursor | ● | ● | ● | ?⃝ | ● | ● |
| DockTerm | ● | ?⃝ | ○ | ○ | ● | ○ |
| Emdash | ● | ● | ?⃝ | ?⃝ | ● | ● |
| GitHub Copilot | ● | ● | ● | ?⃝ | ● | ● |
| Happy | ● | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ |
| Helicon | ○ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ |
| Maestro | ● | ● | ● | ?⃝ | ● | ?⃝ |
| Nimbalyst | ● | ● | ● | ?⃝ | ● | ◐ |
| Nuphos | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| OpenAI Codex | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ |
| Parallel Code | ● | ● | ○ | ?⃝ | ?⃝ | ?⃝ |
| Paseo | ● | ● | ● | ?⃝ | ● | ○ |
| Pragma | ● | ● | ● | ?⃝ | ● | ?⃝ |
| ReevesAgents | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Roamgate | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ |
| Rove | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ |
| Sculptor | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Superset | ● | ● | ● | ◐ | ● | ?⃝ |
| T3 Code | ● | ● | ● | ● | ● | ○ |
| Threadlines | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ |
| tuios | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Vibe Kanban | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| VibeiDE | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ?⃝ |
| Warp | ● | ?⃝ | ◐ | ?⃝ | ● | ● |

## Tasks and automation

| App | Task board | Starts agents from issues | Trackers beyond GitHub | Scheduled or triggered runs | Agents start agents | The app's own tools for agents |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ○ | ◐ | ○ | ● | ● | ● |
| Agentastic | ● | ● | ● | ● | ● | ● |
| Atelier (was Acepe) | ● | ?⃝ | ● | ?⃝ | ?⃝ | ● |
| Claude Code | ?⃝ | ● | ◐ | ● | ● | ● |
| Claude Squad | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ | ?⃝ |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ● | ● |
| Codeg | ● | ● | ● | ● | ● | ● |
| Conductor | ?⃝ | ● | ● | ● | ◐ | ● |
| Cursor | ?⃝ | ● | ● | ● | ● | ● |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Emdash | ○ | ● | ● | ● | ?⃝ | ○ |
| GitHub Copilot | ?⃝ | ● | ● | ● | ● | ● |
| Happy | ?⃝ | ?⃝ | ?⃝ | ● | ● | ● |
| Helicon | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Maestro | ?⃝ | ● | ?⃝ | ● | ● | ● |
| Nimbalyst | ● | ?⃝ | ◐ | ● | ● | ● |
| Nuphos | ?⃝ | ?⃝ | ● | ● | ● | ● |
| OpenAI Codex | ?⃝ | ● | ● | ● | ● | ● |
| Parallel Code | ?⃝ | ● | ◐ | ?⃝ | ● | ● |
| Paseo | ?⃝ | ● | ○ | ● | ● | ● |
| Pragma | ● | ◐ | ?⃝ | ● | ● | ● |
| ReevesAgents | ?⃝ | ○ | ?⃝ | ○ | ● | ● |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ◐ | ◐ | ?⃝ |
| Rove | ● | ● | ◐ | ● | ● | ● |
| Sculptor | ?⃝ | ?⃝ | ● | ◐ | ?⃝ | ● |
| Superset | ● | ● | ● | ● | ● | ● |
| T3 Code | ?⃝ | ?⃝ | ○ | ● | ● | ● |
| Threadlines | ?⃝ | ?⃝ | ?⃝ | ◐ | ● | ● |
| tuios | ?⃝ | ?⃝ | ?⃝ | ◐ | ● | ● |
| Vibe Kanban | ○ | ?⃝ | ?⃝ | ?⃝ | ● | ● |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Warp | ?⃝ | ● | ● | ● | ● | ● |

## Extensions, accounts and cost

| App | MCP or skills catalogue | Plugins | Usage or cost | Spending limits | Several accounts per runtime | Switch when allowance runs out |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ○ | ● | ◐ | ○ | ◐ |
| Agentastic | ● | ● | ● | ?⃝ | ● | ?⃝ |
| Atelier (was Acepe) | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| Claude Code | ● | ● | ● | ● | ?⃝ | ?⃝ |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| CodeAgentSwarm | ● | ?⃝ | ● | ● | ● | ◐ |
| Codeg | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| Conductor | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Cursor | ● | ● | ● | ● | ?⃝ | ?⃝ |
| DockTerm | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| Emdash | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| GitHub Copilot | ● | ● | ● | ● | ● | ?⃝ |
| Happy | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● |
| Helicon | ?⃝ | ?⃝ | ● | ?⃝ | ● | ?⃝ |
| Maestro | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ |
| Nimbalyst | ● | ● | ● | ◐ | ?⃝ | ?⃝ |
| Nuphos | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| OpenAI Codex | ● | ● | ● | ● | ?⃝ | ?⃝ |
| Parallel Code | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| Paseo | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ |
| Pragma | ?⃝ | ● | ● | ?⃝ | ● | ● |
| ReevesAgents | ?⃝ | ?⃝ | ○ | ○ | ?⃝ | ?⃝ |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Rove | ?⃝ | ● | ● | ?⃝ | ?⃝ | ◐ |
| Sculptor | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| Superset | ?⃝ | ?⃝ | ● | ?⃝ | ● | ?⃝ |
| T3 Code | ?⃝ | ?⃝ | ● | ?⃝ | ● | ◐ |
| Threadlines | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ |
| tuios | ?⃝ | ● | ◐ | ?⃝ | ?⃝ | ?⃝ |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ |
| VibeiDE | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ |
| Warp | ● | ?⃝ | ● | ● | ◐ | ?⃝ |

## Organising

| App | Labels or tags | Pins | Archive | Teams | Open source | Self-hosted |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Agents** | ● | ● | ● | ○ | ● | ● |
| Agentastic | ?⃝ | ?⃝ | ● | ?⃝ | ○ | ● |
| Atelier (was Acepe) | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● |
| Claude Code | ?⃝ | ● | ● | ● | ○ | ● |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● |
| CodeAgentSwarm | ● | ?⃝ | ?⃝ | ?⃝ | ○ | ○ |
| Codeg | ● | ● | ?⃝ | ● | ● | ● |
| Conductor | ?⃝ | ● | ● | ● | ○ | ● |
| Cursor | ?⃝ | ● | ● | ● | ○ | ○ |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ○ | ● | ● |
| Emdash | ?⃝ | ● | ● | ?⃝ | ● | ● |
| GitHub Copilot | ?⃝ | ● | ● | ● | ○ | ?⃝ |
| Happy | ?⃝ | ?⃝ | ● | ● | ● | ● |
| Helicon | ?⃝ | ● | ● | ?⃝ | ● | ● |
| Maestro | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● |
| Nimbalyst | ● | ● | ● | ◐ | ● | ◐ |
| Nuphos | ?⃝ | ● | ?⃝ | ● | ● | ● |
| OpenAI Codex | ?⃝ | ● | ● | ● | ◐ | ◐ |
| Parallel Code | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● |
| Paseo | ● | ● | ● | ● | ● | ● |
| Pragma | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● |
| ReevesAgents | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● |
| Roamgate | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● |
| Rove | ?⃝ | ● | ○ | ?⃝ | ● | ● |
| Sculptor | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● |
| Superset | ● | ● | ● | ● | ○ | ● |
| T3 Code | ?⃝ | ● | ● | ?⃝ | ● | ● |
| Threadlines | ?⃝ | ● | ● | ?⃝ | ● | ● |
| tuios | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● |
| Vibe Kanban | ○ | ● | ● | ○ | ● | ● |
| VibeiDE | ?⃝ | ?⃝ | ?⃝ | ◐ | ○ | ?⃝ |
| Warp | ?⃝ | ● | ?⃝ | ● | ◐ | ◐ |

## The apps

- **Agents:** this project. Mac window, Remote on iPhone and iPad, web page, and agentsd hosts.
- **[Agentastic](https://www.agentastic.dev/):** A closed-source native Mac IDE for many agents, with an iPhone companion and cloud agents.
- **[Atelier (was Acepe)](https://github.com/flazouh/atelier):** A young native editor for coding agents over ACP, Mac and Linux.
- **[Claude Code](https://code.claude.com/docs):** Anthropic's agent: CLI, desktop Code tab, web and mobile, with background agents and routines.
- **[Claude Squad](https://github.com/smtg-ai/claude-squad):** A terminal app running agent CLIs in tmux, a worktree each.
- **[CodeAgentSwarm](https://www.codeagentswarm.com/en):** A closed-source desktop app supervising agent CLIs in grid panes, with a task board and budgets.
- **[Codeg](https://github.com/spacering-net/codeg):** An ACP-based desktop and web workspace with a self-hosted server.
- **[Conductor](https://www.conductor.build):** A Mac app running Claude Code and Codex in parallel workspaces, with cloud workspaces and an iOS app.
- **[Cursor](https://cursor.com/docs):** An editor with an Agents Window, cloud agents, Projects and an iOS app.
- **[DockTerm](https://github.com/munvard/dockterm):** An Electron terminal workspace around the claude CLI only.
- **[Emdash](https://github.com/generalaction/emdash):** An open-source desktop app, a worktree per task, locally or on your own SSH hosts.
- **[GitHub Copilot](https://github.com/github/app/releases):** The Copilot app, coding agent, Agent HQ and VS Code sessions.
- **[Happy](https://github.com/slopus/happy):** An open-source harness with desktop, iOS, Android and web clients.
- **[Helicon](https://github.com/HarjjotSinghh/helicon):** An unofficial desktop, web and VS Code client for Meta's Muse Code CLI.
- **[Maestro](https://github.com/RunMaestro/Maestro):** An open-source (AGPL) orchestration command centre with event-triggered prompts.
- **[Nimbalyst](https://nimbalyst.com):** A desktop, mobile and web workspace with a tracker, a wiki and session trees.
- **[Nuphos](https://github.com/nuphos/nuphos):** A team workspace over ACP, local, remote or in cloud containers.
- **[OpenAI Codex](https://developers.openai.com/codex):** OpenAI's agent in the ChatGPT apps, the cloud and a CLI; open source and self-hosted apply to the CLI only.
- **[Parallel Code](https://github.com/johannesjo/parallel-code):** A desktop app with tiled tasks, Docker sandboxes and an Android app.
- **[Paseo](https://github.com/getpaseo/paseo):** An open-source daemon with desktop, iOS, Android, web and CLI clients.
- **[Pragma](https://pragma-app.sh):** A desktop app with a task board, SSH remote projects and the Pragma Go mobile client.
- **[ReevesAgents](https://github.com/mertkayacs/reevesagents):** TUI, local web UI and CLI running agent CLIs in tmux, with an MCP so one agent steers the others.
- **[Roamgate](https://github.com/powerfooI/roamgate):** A web/PWA client for a Herdr terminal-multiplexer server.
- **[Rove](https://github.com/Sma1lboy/rove):** A terminal app with a worktree per task, a daemon, a local kanban and iOS/Android bridges.
- **[Sculptor](https://github.com/imbue-ai/sculptor):** Imbue's desktop app for parallel agents, with a container backend and a CI babysitter.
- **[Superset](https://superset.sh):** A desktop app for parallel agents with its own task tracker, cloud workspaces and an iPhone app.
- **[T3 Code](https://github.com/pingdotgg/t3code):** A local server driven from desktop, web, iOS and Android apps.
- **[Threadlines](https://github.com/Threadlines/threadlines):** A T3 Code fork: desktop and Docker-server workspace, a worktree per thread.
- **[tuios](https://github.com/Gaurav-Gosain/tuios):** A terminal multiplexer and tiling window manager with an agent-state rail and Inbox.
- **[Vibe Kanban](https://github.com/BloopAI/vibe-kanban):** A local web app whose kanban was retired in v0.1.44; the README says it is sunsetting.
- **[VibeiDE](https://vibeide.dev):** A paid, closed-source desktop app with task queues per project.
- **[Warp](https://docs.warp.dev/agent-platform/):** An agentic terminal with the Oz cloud-agent platform.
