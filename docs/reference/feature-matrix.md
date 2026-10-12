---
diataxis: reference
description: Which apps for running several coding agents have which features, Agents included, as found by the weekly competitor check.
---

# Feature matrix of coding-agent apps

This page lists every app the weekly competitor check has found that runs several coding
agents at once, against the full set of features found across them. Agents is in bold,
wherever its score puts it.

- ● the app has it, in full.
- ◐ it has part of it: only by hand, only in an alpha, beta or by request, only on some
  platforms or runtimes, or only through someone else's add-on.
- ○ it does not.
- ?⃝ unknown: the app's docs, changelog, README and code did not say either way.

Each table has a **Score** column, and its rows are sorted by it: ● counts 1, ◐ counts 0.5,
and ○ and ?⃝ count 0, as a percentage of the table's features. An unknown counts as
missing, so an app with thin docs scores low. [Overall score](#overall-score), after the
tables, adds every feature up.

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

| App | Several agents at once | A git worktree per agent | Several runtimes | ACP | Runs with the computer off | Sandboxed tools | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Agentastic | ● | ● | ● | ● | ● | ● | 100% |
| Codeg | ● | ● | ● | ● | ● | ◐ | 92% |
| GitHub Copilot | ● | ● | ● | ◐ | ● | ● | 92% |
| Happy | ● | ● | ● | ◐ | ● | ● | 92% |
| Paseo | ● | ● | ● | ● | ● | ◐ | 92% |
| **Agents** | ● | ● | ● | ● | ◐ | ◐ | 83% |
| Cursor | ● | ● | ○ | ● | ● | ● | 83% |
| Emdash | ● | ● | ● | ● | ● | ?⃝ | 83% |
| Nimbalyst | ● | ● | ● | ◐ | ◐ | ● | 83% |
| Nuphos | ● | ?⃝ | ● | ● | ● | ● | 83% |
| T3 Code | ● | ● | ● | ● | ● | ?⃝ | 83% |
| Threadlines | ● | ● | ● | ● | ● | ?⃝ | 83% |
| tuios | ● | ● | ● | ● | ● | ○ | 83% |
| Warp | ● | ● | ● | ?⃝ | ● | ● | 83% |
| Conductor | ● | ● | ● | ?⃝ | ● | ◐ | 75% |
| Pragma | ● | ● | ● | ◐ | ● | ?⃝ | 75% |
| Superset | ● | ● | ● | ?⃝ | ● | ◐ | 75% |
| Claude Code | ● | ● | ○ | ?⃝ | ● | ● | 67% |
| CodeAgentSwarm | ● | ● | ● | ◐ | ○ | ◐ | 67% |
| OpenAI Codex | ● | ● | ○ | ?⃝ | ● | ● | 67% |
| Parallel Code | ● | ● | ● | ?⃝ | ○ | ● | 67% |
| Roamgate | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Rove | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Vibe Kanban | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Sculptor | ● | ● | ● | ?⃝ | ?⃝ | ◐ | 58% |
| Atelier (was Acepe) | ● | ?⃝ | ● | ● | ?⃝ | ?⃝ | 50% |
| Claude Squad | ● | ● | ● | ○ | ?⃝ | ?⃝ | 50% |
| Maestro | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| VibeiDE | ● | ● | ● | ?⃝ | ○ | ?⃝ | 50% |
| Helicon | ● | ◐ | ○ | ○ | ● | ?⃝ | 42% |
| ReevesAgents | ● | ○ | ● | ?⃝ | ?⃝ | ○ | 33% |
| DockTerm | ● | ?⃝ | ○ | ?⃝ | ○ | ?⃝ | 17% |

## Where you reach it

| App | Windows or Linux desktop | iPhone or iPad app | Android app | Web client | End-to-end encrypted relay | Notifications | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Happy | ● | ● | ● | ● | ● | ● | 100% |
| Paseo | ● | ● | ● | ● | ● | ● | 100% |
| T3 Code | ● | ● | ● | ● | ◐ | ● | 92% |
| Claude Code | ● | ● | ● | ● | ○ | ● | 83% |
| GitHub Copilot | ● | ● | ● | ● | ?⃝ | ● | 83% |
| Nimbalyst | ● | ● | ◐ | ◐ | ● | ● | 83% |
| OpenAI Codex | ● | ● | ● | ● | ?⃝ | ● | 83% |
| Pragma | ● | ● | ● | ● | ○ | ● | 83% |
| Parallel Code | ● | ○ | ● | ● | ◐ | ● | 75% |
| Codeg | ● | ◐ | ◐ | ● | ○ | ● | 67% |
| Cursor | ● | ● | ○ | ● | ○ | ● | 67% |
| CodeAgentSwarm | ● | ◐ | ◐ | ◐ | ?⃝ | ● | 58% |
| Warp | ● | ○ | ○ | ● | ◐ | ● | 58% |
| **Agents** | ○ | ● | ○ | ● | ◐ | ◐ | 50% |
| Maestro | ● | ○ | ○ | ● | ○ | ● | 50% |
| Roamgate | ◐ | ○ | ○ | ● | ◐ | ● | 50% |
| Threadlines | ● | ○ | ○ | ● | ● | ?⃝ | 50% |
| Vibe Kanban | ● | ○ | ○ | ● | ?⃝ | ● | 50% |
| VibeiDE | ● | ○ | ○ | ● | ● | ?⃝ | 50% |
| Agentastic | ○ | ◐ | ○ | ○ | ● | ● | 42% |
| Nuphos | ● | ● | ◐ | ?⃝ | ○ | ?⃝ | 42% |
| Superset | ◐ | ● | ○ | ○ | ?⃝ | ● | 42% |
| DockTerm | ● | ○ | ○ | ○ | ○ | ● | 33% |
| Emdash | ● | ○ | ○ | ○ | ○ | ● | 33% |
| Helicon | ● | ○ | ○ | ● | ○ | ?⃝ | 33% |
| Rove | ○ | ◐ | ◐ | ○ | ○ | ● | 33% |
| Sculptor | ● | ○ | ○ | ?⃝ | ○ | ● | 33% |
| tuios | ○ | ○ | ○ | ● | ○ | ● | 33% |
| Conductor | ○ | ◐ | ?⃝ | ?⃝ | ○ | ● | 25% |
| ReevesAgents | ○ | ○ | ○ | ● | ○ | ○ | 17% |
| Atelier (was Acepe) | ◐ | ○ | ○ | ○ | ○ | ?⃝ | 8% |
| Claude Squad | ○ | ○ | ○ | ○ | ○ | ○ | 0% |

## Following and answering

| App | Shows who needs you | Sessions side by side | Sessions as a tree | Send while it works | Voice or dictation | Rich cards in replies | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| GitHub Copilot | ● | ● | ● | ● | ● | ● | 100% |
| Agentastic | ● | ● | ● | ● | ◐ | ● | 92% |
| Claude Code | ● | ● | ● | ● | ● | ◐ | 92% |
| Warp | ● | ● | ◐ | ● | ● | ● | 92% |
| Cursor | ● | ● | ?⃝ | ● | ● | ● | 83% |
| Nimbalyst | ● | ?⃝ | ● | ● | ● | ● | 83% |
| OpenAI Codex | ● | ● | ◐ | ● | ● | ◐ | 83% |
| Paseo | ● | ● | ◐ | ● | ● | ◐ | 83% |
| Atelier (was Acepe) | ● | ● | ◐ | ● | ● | ○ | 75% |
| Codeg | ● | ● | ◐ | ● | ?⃝ | ● | 75% |
| Happy | ● | ?⃝ | ◐ | ● | ● | ● | 75% |
| Nuphos | ?⃝ | ● | ● | ● | ◐ | ● | 75% |
| Parallel Code | ● | ● | ● | ● | ◐ | ○ | 75% |
| Emdash | ● | ● | ?⃝ | ● | ◐ | ◐ | 67% |
| Maestro | ● | ● | ◐ | ● | ?⃝ | ◐ | 67% |
| Pragma | ● | ● | ◐ | ● | ?⃝ | ◐ | 67% |
| Superset | ● | ● | ◐ | ● | ?⃝ | ◐ | 67% |
| T3 Code | ● | ?⃝ | ◐ | ● | ◐ | ● | 67% |
| Threadlines | ● | ?⃝ | ● | ● | ● | ?⃝ | 67% |
| **Agents** | ● | ○ | ○ | ● | ● | ◐ | 58% |
| DockTerm | ● | ● | ◐ | ?⃝ | ● | ?⃝ | 58% |
| tuios | ● | ● | ◐ | ● | ?⃝ | ○ | 58% |
| CodeAgentSwarm | ● | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | 42% |
| Conductor | ● | ?⃝ | ?⃝ | ● | ?⃝ | ◐ | 42% |
| Helicon | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | 33% |
| ReevesAgents | ?⃝ | ● | ?⃝ | ● | ○ | ○ | 33% |
| Roamgate | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 33% |
| Rove | ● | ?⃝ | ?⃝ | ● | ?⃝ | ○ | 33% |
| Sculptor | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ◐ | 33% |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | 33% |
| VibeiDE | ?⃝ | ● | ?⃝ | ?⃝ | ● | ?⃝ | 33% |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ?⃝ | ○ | 17% |

## Reviewing work

| App | Diff review | Pull requests | Git hosts beyond GitHub | CI checks | A second agent reviews | Score |
|---|:-:|:-:|:-:|:-:|:-:|--:|
| Cursor | ● | ● | ● | ● | ● | 100% |
| GitHub Copilot | ● | ● | ● | ● | ● | 100% |
| Threadlines | ● | ● | ● | ● | ● | 100% |
| Agentastic | ● | ● | ◐ | ● | ● | 90% |
| Codeg | ● | ● | ● | ● | ◐ | 90% |
| Paseo | ● | ● | ● | ● | ◐ | 90% |
| Claude Code | ● | ● | ◐ | ● | ◐ | 80% |
| Conductor | ● | ● | ?⃝ | ● | ● | 80% |
| Roamgate | ● | ● | ● | ● | ?⃝ | 80% |
| Sculptor | ● | ● | ?⃝ | ● | ● | 80% |
| T3 Code | ● | ● | ● | ● | ?⃝ | 80% |
| Nuphos | ◐ | ● | ● | ● | ?⃝ | 70% |
| OpenAI Codex | ● | ● | ◐ | ?⃝ | ● | 70% |
| Superset | ● | ● | ○ | ● | ◐ | 70% |
| **Agents** | ● | ◐ | ○ | ● | ◐ | 60% |
| Atelier (was Acepe) | ● | ● | ○ | ● | ?⃝ | 60% |
| Emdash | ● | ● | ○ | ● | ?⃝ | 60% |
| Nimbalyst | ● | ● | ○ | ● | ?⃝ | 60% |
| Parallel Code | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Pragma | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Rove | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| tuios | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Vibe Kanban | ● | ● | ● | ?⃝ | ?⃝ | 60% |
| Warp | ● | ?⃝ | ● | ?⃝ | ● | 60% |
| Maestro | ● | ● | ?⃝ | ?⃝ | ◐ | 50% |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ● | 40% |
| Happy | ● | ?⃝ | ?⃝ | ?⃝ | ◐ | 30% |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ○ | 20% |
| CodeAgentSwarm | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| DockTerm | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Helicon | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| ReevesAgents | ○ | ○ | ?⃝ | ○ | ?⃝ | 0% |

## Tools in the app

| App | Terminal | Browser or preview | A browser the agent drives | Simulator or emulator panes | File editor | Language servers in the editor | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Agentastic | ● | ● | ● | ?⃝ | ● | ● | 83% |
| Cursor | ● | ● | ● | ?⃝ | ● | ● | 83% |
| GitHub Copilot | ● | ● | ● | ?⃝ | ● | ● | 83% |
| T3 Code | ● | ● | ● | ● | ● | ○ | 83% |
| Claude Code | ● | ● | ● | ◐ | ● | ?⃝ | 75% |
| Nimbalyst | ● | ● | ● | ?⃝ | ● | ◐ | 75% |
| Superset | ● | ● | ● | ◐ | ● | ?⃝ | 75% |
| Atelier (was Acepe) | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Codeg | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Emdash | ● | ● | ?⃝ | ?⃝ | ● | ● | 67% |
| Maestro | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Paseo | ● | ● | ● | ?⃝ | ● | ○ | 67% |
| Pragma | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Warp | ● | ?⃝ | ◐ | ?⃝ | ● | ● | 58% |
| OpenAI Codex | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| Threadlines | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| **Agents** | ● | ◐ | ○ | ○ | ● | ○ | 42% |
| Conductor | ● | ◐ | ?⃝ | ?⃝ | ● | ?⃝ | 42% |
| DockTerm | ● | ?⃝ | ○ | ○ | ● | ○ | 33% |
| Nuphos | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 33% |
| Parallel Code | ● | ● | ○ | ?⃝ | ?⃝ | ?⃝ | 33% |
| Vibe Kanban | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 33% |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ○ | ○ | 25% |
| Roamgate | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ | 25% |
| Rove | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ | 25% |
| VibeiDE | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ?⃝ | 25% |
| Claude Squad | ● | ?⃝ | ○ | ○ | ?⃝ | ○ | 17% |
| Happy | ● | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ | 17% |
| ReevesAgents | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| Sculptor | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| tuios | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| Helicon | ○ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ | 0% |

## Tasks and automation

| App | Task board | Starts agents from issues | Trackers beyond GitHub | Scheduled or triggered runs | Agents start agents | The app's own tools for agents | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Agentastic | ● | ● | ● | ● | ● | ● | 100% |
| Codeg | ● | ● | ● | ● | ● | ● | 100% |
| Superset | ● | ● | ● | ● | ● | ● | 100% |
| Rove | ● | ● | ◐ | ● | ● | ● | 92% |
| Cursor | ?⃝ | ● | ● | ● | ● | ● | 83% |
| GitHub Copilot | ?⃝ | ● | ● | ● | ● | ● | 83% |
| OpenAI Codex | ?⃝ | ● | ● | ● | ● | ● | 83% |
| Warp | ?⃝ | ● | ● | ● | ● | ● | 83% |
| Claude Code | ?⃝ | ● | ◐ | ● | ● | ● | 75% |
| Conductor | ?⃝ | ● | ● | ● | ◐ | ● | 75% |
| Nimbalyst | ● | ?⃝ | ◐ | ● | ● | ● | 75% |
| Pragma | ● | ◐ | ?⃝ | ● | ● | ● | 75% |
| Maestro | ?⃝ | ● | ?⃝ | ● | ● | ● | 67% |
| Nuphos | ?⃝ | ?⃝ | ● | ● | ● | ● | 67% |
| Paseo | ?⃝ | ● | ○ | ● | ● | ● | 67% |
| **Agents** | ○ | ◐ | ○ | ● | ● | ● | 58% |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ● | ● | 58% |
| Parallel Code | ?⃝ | ● | ◐ | ?⃝ | ● | ● | 58% |
| Atelier (was Acepe) | ● | ?⃝ | ● | ?⃝ | ?⃝ | ● | 50% |
| Emdash | ○ | ● | ● | ● | ?⃝ | ○ | 50% |
| Happy | ?⃝ | ?⃝ | ?⃝ | ● | ● | ● | 50% |
| T3 Code | ?⃝ | ?⃝ | ○ | ● | ● | ● | 50% |
| Sculptor | ?⃝ | ?⃝ | ● | ◐ | ?⃝ | ● | 42% |
| Threadlines | ?⃝ | ?⃝ | ?⃝ | ◐ | ● | ● | 42% |
| tuios | ?⃝ | ?⃝ | ?⃝ | ◐ | ● | ● | 42% |
| ReevesAgents | ?⃝ | ○ | ?⃝ | ○ | ● | ● | 33% |
| Vibe Kanban | ○ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ◐ | ◐ | ?⃝ | 17% |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| Claude Squad | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ | ?⃝ | 0% |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |
| Helicon | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |

## Extensions, accounts and cost

| App | MCP or skills catalogue | Plugins | Usage or cost | Spending limits | Several accounts per runtime | Switch when allowance runs out | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| GitHub Copilot | ● | ● | ● | ● | ● | ?⃝ | 83% |
| CodeAgentSwarm | ● | ?⃝ | ● | ● | ● | ◐ | 75% |
| Agentastic | ● | ● | ● | ?⃝ | ● | ?⃝ | 67% |
| Claude Code | ● | ● | ● | ● | ?⃝ | ?⃝ | 67% |
| Cursor | ● | ● | ● | ● | ?⃝ | ?⃝ | 67% |
| OpenAI Codex | ● | ● | ● | ● | ?⃝ | ?⃝ | 67% |
| Pragma | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Nimbalyst | ● | ● | ● | ◐ | ?⃝ | ?⃝ | 58% |
| Warp | ● | ?⃝ | ● | ● | ◐ | ?⃝ | 58% |
| **Agents** | ● | ○ | ● | ◐ | ○ | ◐ | 50% |
| Happy | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● | 50% |
| Maestro | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 50% |
| Paseo | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 50% |
| Threadlines | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 50% |
| Rove | ?⃝ | ● | ● | ?⃝ | ?⃝ | ◐ | 42% |
| T3 Code | ?⃝ | ?⃝ | ● | ?⃝ | ● | ◐ | 42% |
| Codeg | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 33% |
| Emdash | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 33% |
| Helicon | ?⃝ | ?⃝ | ● | ?⃝ | ● | ?⃝ | 33% |
| Superset | ?⃝ | ?⃝ | ● | ?⃝ | ● | ?⃝ | 33% |
| tuios | ?⃝ | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | 25% |
| Atelier (was Acepe) | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 17% |
| DockTerm | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 17% |
| Nuphos | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 17% |
| Parallel Code | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 17% |
| Sculptor | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 17% |
| VibeiDE | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 17% |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |
| Conductor | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |
| ReevesAgents | ?⃝ | ?⃝ | ○ | ○ | ?⃝ | ?⃝ | 0% |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |

## Organising

| App | Labels or tags | Pins | Archive | Teams | Open source | Self-hosted | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Paseo | ● | ● | ● | ● | ● | ● | 100% |
| **Agents** | ● | ● | ● | ○ | ● | ● | 83% |
| Codeg | ● | ● | ?⃝ | ● | ● | ● | 83% |
| Nimbalyst | ● | ● | ● | ◐ | ● | ◐ | 83% |
| Superset | ● | ● | ● | ● | ○ | ● | 83% |
| Claude Code | ?⃝ | ● | ● | ● | ○ | ● | 67% |
| Conductor | ?⃝ | ● | ● | ● | ○ | ● | 67% |
| Emdash | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Happy | ?⃝ | ?⃝ | ● | ● | ● | ● | 67% |
| Helicon | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Nuphos | ?⃝ | ● | ?⃝ | ● | ● | ● | 67% |
| OpenAI Codex | ?⃝ | ● | ● | ● | ◐ | ◐ | 67% |
| T3 Code | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Threadlines | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Vibe Kanban | ○ | ● | ● | ○ | ● | ● | 67% |
| Atelier (was Acepe) | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● | 50% |
| Cursor | ?⃝ | ● | ● | ● | ○ | ○ | 50% |
| GitHub Copilot | ?⃝ | ● | ● | ● | ○ | ?⃝ | 50% |
| Maestro | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● | 50% |
| Pragma | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● | 50% |
| ReevesAgents | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● | 50% |
| Roamgate | ?⃝ | ● | ?⃝ | ?⃝ | ● | ● | 50% |
| Rove | ?⃝ | ● | ○ | ?⃝ | ● | ● | 50% |
| Warp | ?⃝ | ● | ?⃝ | ● | ◐ | ◐ | 50% |
| Agentastic | ?⃝ | ?⃝ | ● | ?⃝ | ○ | ● | 33% |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ○ | ● | ● | 33% |
| Parallel Code | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| Sculptor | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| tuios | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| CodeAgentSwarm | ● | ?⃝ | ?⃝ | ?⃝ | ○ | ○ | 17% |
| VibeiDE | ?⃝ | ?⃝ | ?⃝ | ◐ | ○ | ?⃝ | 8% |

## Overall score

Each app's score in every table, and overall: its points over all 47 features. Sorted by the overall score.

| Rank | App | Running | Reach | Following | Reviewing | Tools | Tasks | Extensions | Organising | Overall |
|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | GitHub Copilot | 92% | 83% | 100% | 100% | 83% | 83% | 83% | 50% | **84%** |
| 2 | Paseo | 92% | 100% | 83% | 90% | 67% | 67% | 50% | 100% | **81%** |
| 3 | Cursor | 83% | 67% | 83% | 100% | 83% | 83% | 67% | 50% | **77%** |
| 4 | Agentastic | 100% | 42% | 92% | 90% | 83% | 100% | 67% | 33% | **76%** |
| 4 | Claude Code | 67% | 83% | 92% | 80% | 75% | 75% | 67% | 67% | **76%** |
| 4 | Codeg | 92% | 67% | 75% | 90% | 67% | 100% | 33% | 83% | **76%** |
| 4 | Nimbalyst | 83% | 83% | 83% | 60% | 75% | 75% | 58% | 83% | **76%** |
| 8 | OpenAI Codex | 67% | 83% | 83% | 70% | 50% | 83% | 67% | 67% | **71%** |
| 9 | T3 Code | 83% | 92% | 67% | 80% | 83% | 50% | 42% | 67% | **70%** |
| 10 | Pragma | 75% | 83% | 67% | 60% | 67% | 75% | 67% | 50% | **68%** |
| 10 | Superset | 75% | 42% | 67% | 70% | 75% | 100% | 33% | 83% | **68%** |
| 10 | Warp | 83% | 58% | 92% | 60% | 58% | 83% | 58% | 50% | **68%** |
| 13 | Threadlines | 83% | 50% | 67% | 100% | 50% | 42% | 50% | 67% | **63%** |
| 14 | **Agents** | 83% | 50% | 58% | 60% | 42% | 58% | 50% | 83% | **61%** |
| 14 | Happy | 92% | 100% | 75% | 30% | 17% | 50% | 50% | 67% | **61%** |
| 16 | Emdash | 83% | 33% | 67% | 60% | 67% | 50% | 33% | 67% | **57%** |
| 17 | Maestro | 50% | 50% | 67% | 50% | 67% | 67% | 50% | 50% | **56%** |
| 17 | Nuphos | 83% | 42% | 75% | 70% | 33% | 67% | 17% | 67% | **56%** |
| 19 | Parallel Code | 67% | 75% | 75% | 60% | 33% | 58% | 17% | 33% | **52%** |
| 20 | Conductor | 75% | 25% | 42% | 80% | 42% | 75% | 0% | 67% | **50%** |
| 20 | Rove | 67% | 33% | 33% | 60% | 25% | 92% | 42% | 50% | **50%** |
| 22 | Atelier (was Acepe) | 50% | 8% | 75% | 60% | 67% | 50% | 17% | 50% | **47%** |
| 23 | CodeAgentSwarm | 67% | 58% | 42% | 20% | 25% | 58% | 75% | 17% | **46%** |
| 24 | Vibe Kanban | 67% | 50% | 33% | 60% | 33% | 33% | 17% | 67% | **45%** |
| 25 | tuios | 83% | 33% | 58% | 60% | 17% | 42% | 25% | 33% | **44%** |
| 26 | Roamgate | 67% | 50% | 33% | 80% | 25% | 17% | 0% | 50% | **39%** |
| 27 | Sculptor | 58% | 33% | 33% | 80% | 17% | 42% | 17% | 33% | **38%** |
| 28 | VibeiDE | 50% | 50% | 33% | 40% | 25% | 17% | 17% | 8% | **30%** |
| 29 | Helicon | 42% | 33% | 33% | 20% | 0% | 0% | 33% | 67% | **29%** |
| 30 | DockTerm | 17% | 33% | 58% | 20% | 33% | 0% | 17% | 33% | **27%** |
| 31 | ReevesAgents | 33% | 17% | 33% | 0% | 17% | 33% | 0% | 50% | **23%** |
| 32 | Claude Squad | 50% | 0% | 17% | 20% | 17% | 0% | 0% | 33% | **17%** |

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
