---
diataxis: reference
description: Which apps for running several coding agents have which features, Agents included, as found by the competitor check, run once per release.
---

# Feature matrix of coding-agent apps

This page lists every app the competitor check has found that runs several coding
agents at once, against the full set of features found across them. Agents is in bold,
wherever its score puts it.

- ● the app has it, in full.
- ◐ it has part of it: only by hand, only in an alpha, beta or by request, only on some
  platforms or runtimes, or only through someone else's add-on.
- ○ it does not.
- ?⃝ unknown: the app's docs, changelog, README and code did not say either way.

Each table has a **Score** column, and its rows are sorted by it: ● counts 1, ◐ counts 0.5,
and ○ and ?⃝ count 0, as a percentage of the table's features. An unknown counts as
missing, so an app with thin docs scores low. Two features are shown but not scored:
**Browser or preview**, since every agent already has a full browser on the computer, and
**Switch when allowance runs out**, which Agents left out on purpose in favour of a new
agent reading another's work.

A feature that comes from an MCP server is counted the same way for every app:

- ● when the app itself shows it, including through a view drawn from the app's own
  server, such as Agents' own test view.
- ◐ when a server from the app's own MCP catalogue gives the agent the feature, with
  nothing shown in the app. Every catalogue here carries Playwright, Linear, Jira and
  GitLab servers, as the official MCP registry does, so an app with a catalogue has at
  least ◐ for a browser the agent drives, trackers beyond GitHub and git hosts beyond
  GitHub.
- ○ when it takes a server added by hand, or cannot be done.

Passing each runtime's own sandbox through counts as sandboxed tools: an app is not marked
down for a runtime that has none. [Overall score](#overall-score), after the
tables, adds every feature up.

The matrix was filled in on 2026-10-12 from each app's own docs, changelog, README,
releases and, where open, source. Agents' row was last brought up to date on 2026-10-29. Every app is held to the same bar, Agents included: a ●
needs the whole feature, documented by the app itself, and a ○ needs evidence, such as an
app that ships for macOS alone having no Android app. Once per release, after the
Competitor check, the Feature matrix workflow (`.agents/workflows/feature-matrix.md`)
brings it up to date from the merged changes since its last update and the Competitor check's report.
The reports in `~/.agents/reviews/competitors/` give the sources, and
[Sources for leases, waits, workflows in the repository and live documents](#sources-for-leases-waits-workflows-in-the-repository-and-live-documents)
gives them for the four features added on 2026-10-15. Apps change every week, so check a row against the app before relying
on it.

## Where Agents falls short

Agents' ◐ cells, and why:

- **Spending limits:** in money or in tokens (#838), so only for runtimes that report a
  price or tokens. Cursor, Antigravity and Grok report neither, and run past every
  limit. See [Limit spending](../how-to/limit-spending.md).
- **A browser the agent drives:** through the Playwright server from the MCP marketplace,
  with nothing shown in the app, or with **Use Chrome** (#1837), which drives the person's
  own Chrome for Claude alone, once its extension is installed.
- **Several accounts per runtime:** for Claude and Codex alone (#840). The person picks
  the account when a session starts. See
  [More than one account](runtimes.md#more-than-one-account).

Agents has none of these at all:

- Android app (#810), Windows or Linux desktop (#811).
- Open source: the source is visible on GitHub, but all rights are reserved (#2110).

## What each feature means

**Running agents**

- **Several agents at once:** Several agent sessions run at the same time.
- **A git worktree per agent:** Each agent can work in its own git worktree and branch, made by the app.
- **Several runtimes:** It runs more than one vendor's agent, such as Claude Code and Codex.
- **ACP:** It speaks the Agent Client Protocol.
- **Runs with the computer off:** Agents run on a remote or cloud machine, and can be reached, while the person's own computer is off.
- **End-to-end encrypted relay:** A phone or browser away from home reaches the agents through a relay that cannot read them.
- **Notifications:** Push or system notifications when an agent needs the person or finishes.

**Following and answering**

- **Shows who needs you:** A status shows which agent is waiting on the person.
- **Sessions side by side:** Several sessions are visible at once, in a split, grid or separate windows.
- **Sessions as a tree:** Sessions are shown under the session that started them.
- **Send while it works:** A message can be sent, queued or used to steer while the agent is working.
- **Voice or dictation:** Prompts can be spoken.
- **Rich cards in replies:** Agent replies can hold interactive cards, tables or charts, beyond Markdown.
- **Live documents:** A document the agent writes opens beside the chat and fills in as it is written, with each change marked. A file pane that only reloads the file has part of it.

**Reviewing work**

- **Diff review:** The agent's changes can be reviewed as a diff in the app.
- **Pull requests:** Pull requests can be created, reviewed and merged in the app.
- **Git hosts beyond GitHub:** Pull requests and checks work with GitLab, Bitbucket or others too.
- **CI checks:** CI status is shown or watched.
- **A second agent reviews:** Another agent reviewing the first one's work is a feature of the app.

**Tools in the app**

- **Terminal:** A terminal is built in.
- **Starts agents from issues:** An issue starts an agent, or an agent is started from an issue in one step.
- **Trackers beyond GitHub:** Linear, Jira or other trackers are connected in the app.
- **Scheduled or triggered runs:** Agents start on a schedule or on an event.
- **Agents start agents:** An agent can start and manage other agents.
- **The app's own tools for agents:** The app gives its agents tools of its own, over MCP or a CLI.
- **Leases on shared resources:** Agents take turns with a simulator, a browser, the screen or anything named: one holds it, and the others wait in line.
- **Wait for an event without polling:** An agent ends its turn, spends nothing, and is woken when another agent finishes, a branch moves, the computer wakes or the person comes back. Being woken only by its own subagents, by one kind of event, or by a watch the agent writes itself, or waiting inside a tool call, is part of it.
- **Workflows as files in the repository:** Schedule or event triggers are defined in a file beside the code and reviewed like code. A setting in the app or in a cloud does not count here, though it counts for "Scheduled or triggered runs".

**Extensions, accounts and cost**

- **MCP or skills catalogue:** A catalogue or marketplace to add connectors (MCP servers) or skills from.
- **Plugins:** The app has plugins or extensions of its own.
- **Usage or cost:** Usage, allowance or cost is shown.
- **Spending limits:** Spending can be capped.
- **Several accounts per runtime:** More than one account for the same runtime, such as two Claude logins.
- **Switch when allowance runs out** (not scored): It moves to another runtime or account, by itself, when one runs out.

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
| **Agents** | ● | ● | ● | ● | ● | ● | 100% |
| Codeg | ● | ● | ● | ● | ● | ● | 100% |
| Paseo | ● | ● | ● | ● | ● | ● | 100% |
| GitHub Copilot | ● | ● | ● | ◐ | ● | ● | 92% |
| Happy | ● | ● | ● | ◐ | ● | ● | 92% |
| Cursor | ● | ● | ○ | ● | ● | ● | 83% |
| Emdash | ● | ● | ● | ● | ● | ?⃝ | 83% |
| Nimbalyst | ● | ● | ● | ◐ | ◐ | ● | 83% |
| Nuphos | ● | ?⃝ | ● | ● | ● | ● | 83% |
| T3 Code | ● | ● | ● | ● | ● | ?⃝ | 83% |
| Threadlines | ● | ● | ● | ● | ● | ?⃝ | 83% |
| tuios | ● | ● | ● | ● | ● | ○ | 83% |
| Warp | ● | ● | ● | ?⃝ | ● | ● | 83% |
| Conductor | ● | ● | ● | ?⃝ | ● | ◐ | 75% |
| Orca | ● | ● | ● | ◐ | ◐ | ◐ | 75% |
| Paradev (was Superset) | ● | ● | ● | ?⃝ | ● | ◐ | 75% |
| Pragma | ● | ● | ● | ◐ | ● | ?⃝ | 75% |
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
| Ace | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 33% |
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
| **Agents** | ○ | ● | ○ | ● | ● | ● | 67% |
| Codeg | ● | ◐ | ◐ | ● | ○ | ● | 67% |
| Cursor | ● | ● | ○ | ● | ○ | ● | 67% |
| Orca | ● | ◐ | ◐ | ◐ | ◐ | ● | 67% |
| Threadlines | ● | ○ | ○ | ● | ● | ● | 67% |
| CodeAgentSwarm | ● | ◐ | ◐ | ◐ | ?⃝ | ● | 58% |
| Nuphos | ● | ● | ◐ | ?⃝ | ○ | ● | 58% |
| Warp | ● | ○ | ○ | ● | ◐ | ● | 58% |
| Maestro | ● | ○ | ○ | ● | ○ | ● | 50% |
| Roamgate | ◐ | ○ | ○ | ● | ◐ | ● | 50% |
| Vibe Kanban | ● | ○ | ○ | ● | ?⃝ | ● | 50% |
| VibeiDE | ● | ○ | ○ | ● | ● | ?⃝ | 50% |
| Agentastic | ○ | ◐ | ○ | ○ | ● | ● | 42% |
| Paradev (was Superset) | ◐ | ● | ○ | ○ | ?⃝ | ● | 42% |
| DockTerm | ● | ○ | ○ | ○ | ○ | ● | 33% |
| Emdash | ● | ○ | ○ | ○ | ○ | ● | 33% |
| Helicon | ● | ○ | ○ | ● | ○ | ?⃝ | 33% |
| Rove | ○ | ◐ | ◐ | ○ | ○ | ● | 33% |
| Sculptor | ● | ○ | ○ | ?⃝ | ○ | ● | 33% |
| tuios | ○ | ○ | ○ | ● | ○ | ● | 33% |
| Conductor | ○ | ◐ | ?⃝ | ?⃝ | ○ | ● | 25% |
| Ace | ● | ○ | ○ | ?⃝ | ?⃝ | ?⃝ | 17% |
| ReevesAgents | ○ | ○ | ○ | ● | ○ | ○ | 17% |
| Atelier (was Acepe) | ◐ | ○ | ○ | ○ | ○ | ?⃝ | 8% |
| Claude Squad | ○ | ○ | ○ | ○ | ○ | ○ | 0% |

## Following and answering

| App | Shows who needs you | Sessions side by side | Sessions as a tree | Send while it works | Voice or dictation | Rich cards in replies | Live documents | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| **Agents** | ● | ● | ● | ● | ● | ● | ● | 100% |
| GitHub Copilot | ● | ● | ● | ● | ● | ● | ● | 100% |
| Cursor | ● | ● | ?⃝ | ● | ● | ● | ● | 86% |
| Nimbalyst | ● | ?⃝ | ● | ● | ● | ● | ● | 86% |
| Warp | ● | ● | ◐ | ● | ● | ● | ◐ | 86% |
| Agentastic | ● | ● | ● | ● | ◐ | ● | ?⃝ | 79% |
| Claude Code | ● | ● | ● | ● | ● | ◐ | ?⃝ | 79% |
| Nuphos | ● | ● | ● | ● | ◐ | ● | ?⃝ | 79% |
| Parallel Code | ● | ● | ● | ● | ◐ | ○ | ● | 79% |
| Atelier (was Acepe) | ● | ● | ◐ | ● | ● | ○ | ◐ | 71% |
| OpenAI Codex | ● | ● | ◐ | ● | ● | ◐ | ?⃝ | 71% |
| Orca | ● | ● | ◐ | ◐ | ● | ◐ | ◐ | 71% |
| Paradev (was Superset) | ● | ● | ◐ | ● | ● | ◐ | ?⃝ | 71% |
| Paseo | ● | ● | ◐ | ● | ● | ◐ | ?⃝ | 71% |
| Threadlines | ● | ?⃝ | ● | ● | ● | ● | ?⃝ | 71% |
| Codeg | ● | ● | ◐ | ● | ?⃝ | ● | ?⃝ | 64% |
| Happy | ● | ?⃝ | ◐ | ● | ● | ● | ?⃝ | 64% |
| T3 Code | ● | ?⃝ | ◐ | ● | ◐ | ● | ◐ | 64% |
| Ace | ● | ?⃝ | ● | ?⃝ | ● | ● | ?⃝ | 57% |
| Emdash | ● | ● | ?⃝ | ● | ◐ | ◐ | ?⃝ | 57% |
| Maestro | ● | ● | ◐ | ● | ?⃝ | ◐ | ?⃝ | 57% |
| Pragma | ● | ● | ◐ | ● | ?⃝ | ◐ | ?⃝ | 57% |
| DockTerm | ● | ● | ◐ | ?⃝ | ● | ?⃝ | ?⃝ | 50% |
| tuios | ● | ● | ◐ | ● | ?⃝ | ○ | ○ | 50% |
| Conductor | ● | ?⃝ | ?⃝ | ● | ◐ | ◐ | ?⃝ | 43% |
| CodeAgentSwarm | ● | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 36% |
| Helicon | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 29% |
| ReevesAgents | ?⃝ | ● | ?⃝ | ● | ○ | ○ | ○ | 29% |
| Roamgate | ● | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ | 29% |
| Rove | ● | ?⃝ | ?⃝ | ● | ?⃝ | ○ | ○ | 29% |
| Sculptor | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ◐ | ?⃝ | 29% |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 29% |
| VibeiDE | ?⃝ | ● | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | 29% |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ?⃝ | ○ | ○ | 14% |

## Reviewing work

| App | Diff review | Pull requests | Git hosts beyond GitHub | CI checks | A second agent reviews | Score |
|---|:-:|:-:|:-:|:-:|:-:|--:|
| **Agents** | ● | ● | ● | ● | ● | 100% |
| Cursor | ● | ● | ● | ● | ● | 100% |
| GitHub Copilot | ● | ● | ● | ● | ● | 100% |
| Threadlines | ● | ● | ● | ● | ● | 100% |
| Agentastic | ● | ● | ◐ | ● | ● | 90% |
| Codeg | ● | ● | ● | ● | ◐ | 90% |
| Paseo | ● | ● | ● | ● | ◐ | 90% |
| Claude Code | ● | ● | ◐ | ● | ◐ | 80% |
| Conductor | ● | ● | ?⃝ | ● | ● | 80% |
| Orca | ● | ● | ● | ● | ○ | 80% |
| Roamgate | ● | ● | ● | ● | ?⃝ | 80% |
| Sculptor | ● | ● | ?⃝ | ● | ● | 80% |
| T3 Code | ● | ● | ● | ● | ?⃝ | 80% |
| Emdash | ● | ● | ◐ | ● | ?⃝ | 70% |
| Nimbalyst | ● | ● | ◐ | ● | ?⃝ | 70% |
| Nuphos | ◐ | ● | ● | ● | ?⃝ | 70% |
| OpenAI Codex | ● | ● | ◐ | ?⃝ | ● | 70% |
| Paradev (was Superset) | ● | ● | ○ | ● | ◐ | 70% |
| Atelier (was Acepe) | ● | ● | ○ | ● | ?⃝ | 60% |
| Parallel Code | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Pragma | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Rove | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| tuios | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Vibe Kanban | ● | ● | ● | ?⃝ | ?⃝ | 60% |
| Warp | ● | ?⃝ | ● | ?⃝ | ● | 60% |
| Maestro | ● | ● | ?⃝ | ?⃝ | ◐ | 50% |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ● | 40% |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | 30% |
| Happy | ● | ?⃝ | ?⃝ | ?⃝ | ◐ | 30% |
| Ace | ● | ○ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Claude Squad | ● | ?⃝ | ○ | ?⃝ | ○ | 20% |
| DockTerm | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Helicon | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| ReevesAgents | ○ | ○ | ?⃝ | ○ | ?⃝ | 0% |

## Tools in the app

| App | Terminal | Browser or preview (not scored) | A browser the agent drives | Simulator or emulator panes | File editor | Language servers in the editor | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| **Agents** | ● | ◐ | ◐ | ● | ● | ● | 90% |
| Agentastic | ● | ● | ● | ?⃝ | ● | ● | 80% |
| Cursor | ● | ● | ● | ?⃝ | ● | ● | 80% |
| GitHub Copilot | ● | ● | ● | ?⃝ | ● | ● | 80% |
| T3 Code | ● | ● | ● | ● | ● | ○ | 80% |
| Claude Code | ● | ● | ● | ◐ | ● | ?⃝ | 70% |
| Emdash | ● | ● | ◐ | ?⃝ | ● | ● | 70% |
| Nimbalyst | ● | ● | ● | ?⃝ | ● | ◐ | 70% |
| Orca | ● | ● | ● | ◐ | ● | ○ | 70% |
| Warp | ● | ?⃝ | ◐ | ?⃝ | ● | ● | 70% |
| Atelier (was Acepe) | ?⃝ | ● | ● | ?⃝ | ● | ● | 60% |
| Codeg | ● | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Maestro | ● | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Paradev (was Superset) | ● | ● | ● | ○ | ● | ?⃝ | 60% |
| Paseo | ● | ● | ● | ?⃝ | ● | ○ | 60% |
| Pragma | ● | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Ace | ● | ○ | ○ | ?⃝ | ● | ?⃝ | 40% |
| Conductor | ● | ◐ | ?⃝ | ?⃝ | ● | ?⃝ | 40% |
| DockTerm | ● | ?⃝ | ○ | ○ | ● | ○ | 40% |
| Nuphos | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 40% |
| OpenAI Codex | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 40% |
| Threadlines | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 40% |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ○ | ○ | 30% |
| Vibe Kanban | ● | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | 30% |
| VibeiDE | ● | ?⃝ | ◐ | ?⃝ | ?⃝ | ?⃝ | 30% |
| Claude Squad | ● | ?⃝ | ○ | ○ | ?⃝ | ○ | 20% |
| Happy | ● | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ | 20% |
| Parallel Code | ● | ● | ○ | ?⃝ | ?⃝ | ?⃝ | 20% |
| ReevesAgents | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Roamgate | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ | 20% |
| Rove | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | ○ | 20% |
| Sculptor | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| tuios | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Helicon | ○ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ | 0% |

## Tasks and automation

| App | Task board | Starts agents from issues | Trackers beyond GitHub | Scheduled or triggered runs | Agents start agents | The app's own tools for agents | Leases on shared resources | Wait for an event without polling | Workflows as files in the repository | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| **Agents** | ● | ● | ● | ● | ● | ● | ● | ● | ● | 100% |
| Orca | ● | ● | ● | ● | ● | ● | ○ | ◐ | ○ | 72% |
| Paradev (was Superset) | ● | ● | ● | ● | ● | ● | ?⃝ | ◐ | ?⃝ | 72% |
| Agentastic | ● | ● | ● | ● | ● | ● | ?⃝ | ?⃝ | ○ | 67% |
| Claude Code | ?⃝ | ● | ◐ | ● | ● | ● | ?⃝ | ◐ | ● | 67% |
| Codeg | ● | ● | ● | ● | ● | ● | ○ | ○ | ○ | 67% |
| Cursor | ?⃝ | ● | ● | ● | ● | ● | ?⃝ | ?⃝ | ● | 67% |
| OpenAI Codex | ?⃝ | ● | ● | ● | ● | ● | ?⃝ | ?⃝ | ● | 67% |
| Warp | ?⃝ | ● | ● | ● | ● | ● | ?⃝ | ?⃝ | ● | 67% |
| GitHub Copilot | ?⃝ | ● | ● | ● | ● | ● | ?⃝ | ?⃝ | ◐ | 61% |
| Paseo | ?⃝ | ● | ○ | ● | ● | ● | ○ | ◐ | ● | 61% |
| Rove | ● | ● | ◐ | ● | ● | ● | ○ | ○ | ○ | 61% |
| Maestro | ?⃝ | ● | ?⃝ | ● | ● | ● | ○ | ○ | ● | 56% |
| Parallel Code | ● | ● | ◐ | ?⃝ | ● | ● | ○ | ◐ | ○ | 56% |
| Conductor | ?⃝ | ● | ● | ● | ◐ | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| Nimbalyst | ● | ?⃝ | ◐ | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| Pragma | ● | ◐ | ?⃝ | ● | ● | ● | ?⃝ | ?⃝ | ?⃝ | 50% |
| Threadlines | ?⃝ | ● | ?⃝ | ● | ● | ● | ○ | ◐ | ○ | 50% |
| Nuphos | ?⃝ | ?⃝ | ● | ● | ● | ● | ○ | ○ | ○ | 44% |
| CodeAgentSwarm | ● | ?⃝ | ◐ | ?⃝ | ● | ● | ?⃝ | ?⃝ | ?⃝ | 39% |
| T3 Code | ?⃝ | ?⃝ | ○ | ● | ● | ● | ○ | ◐ | ○ | 39% |
| Atelier (was Acepe) | ● | ?⃝ | ● | ?⃝ | ?⃝ | ● | ○ | ○ | ○ | 33% |
| Emdash | ○ | ● | ● | ● | ?⃝ | ○ | ○ | ○ | ○ | 33% |
| Happy | ?⃝ | ?⃝ | ?⃝ | ● | ● | ● | ○ | ○ | ○ | 33% |
| Sculptor | ?⃝ | ?⃝ | ● | ◐ | ?⃝ | ● | ○ | ◐ | ○ | 33% |
| tuios | ?⃝ | ?⃝ | ?⃝ | ◐ | ● | ● | ○ | ◐ | ○ | 33% |
| Vibe Kanban | ○ | ?⃝ | ◐ | ?⃝ | ● | ● | ○ | ○ | ○ | 28% |
| ReevesAgents | ?⃝ | ○ | ?⃝ | ○ | ● | ● | ○ | ○ | ○ | 22% |
| Ace | ○ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 11% |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ◐ | ◐ | ?⃝ | ○ | ○ | ○ | 11% |
| VibeiDE | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 11% |
| Helicon | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ | ◐ | ○ | 6% |
| Claude Squad | ?⃝ | ?⃝ | ○ | ?⃝ | ?⃝ | ?⃝ | ○ | ○ | ○ | 0% |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ○ | ○ | ○ | 0% |

## Extensions, accounts and cost

| App | MCP or skills catalogue | Plugins | Usage or cost | Spending limits | Several accounts per runtime | Switch when allowance runs out (not scored) | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| GitHub Copilot | ● | ● | ● | ● | ● | ?⃝ | 100% |
| Agentastic | ● | ● | ● | ?⃝ | ● | ?⃝ | 80% |
| **Agents** | ● | ● | ● | ◐ | ◐ | ◐ | 80% |
| Claude Code | ● | ● | ● | ● | ?⃝ | ?⃝ | 80% |
| CodeAgentSwarm | ● | ?⃝ | ● | ● | ● | ◐ | 80% |
| Cursor | ● | ● | ● | ● | ?⃝ | ?⃝ | 80% |
| OpenAI Codex | ● | ● | ● | ● | ?⃝ | ?⃝ | 80% |
| Paradev (was Superset) | ● | ● | ● | ?⃝ | ● | ?⃝ | 80% |
| Nimbalyst | ● | ● | ● | ◐ | ?⃝ | ?⃝ | 70% |
| Warp | ● | ?⃝ | ● | ● | ◐ | ?⃝ | 70% |
| Maestro | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Orca | ◐ | ◐ | ● | ○ | ● | ○ | 60% |
| Paseo | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Pragma | ?⃝ | ● | ● | ?⃝ | ● | ● | 60% |
| Threadlines | ?⃝ | ● | ● | ?⃝ | ● | ?⃝ | 60% |
| Ace | ?⃝ | ?⃝ | ● | ?⃝ | ● | ◐ | 40% |
| Codeg | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 40% |
| Emdash | ● | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 40% |
| Happy | ?⃝ | ?⃝ | ● | ?⃝ | ● | ● | 40% |
| Helicon | ?⃝ | ?⃝ | ● | ?⃝ | ● | ?⃝ | 40% |
| Rove | ?⃝ | ● | ● | ?⃝ | ?⃝ | ◐ | 40% |
| T3 Code | ?⃝ | ?⃝ | ● | ?⃝ | ● | ◐ | 40% |
| tuios | ?⃝ | ● | ◐ | ?⃝ | ?⃝ | ?⃝ | 30% |
| Atelier (was Acepe) | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 20% |
| DockTerm | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 20% |
| Nuphos | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 20% |
| Parallel Code | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 20% |
| Sculptor | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| Vibe Kanban | ● | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 20% |
| VibeiDE | ?⃝ | ?⃝ | ● | ?⃝ | ?⃝ | ?⃝ | 20% |
| Conductor | ?⃝ | ?⃝ | ◐ | ?⃝ | ?⃝ | ?⃝ | 10% |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |
| ReevesAgents | ?⃝ | ?⃝ | ○ | ○ | ?⃝ | ?⃝ | 0% |
| Roamgate | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ?⃝ | 0% |

## Organising

| App | Labels or tags | Pins | Archive | Teams | Open source | Self-hosted | Score |
|---|:-:|:-:|:-:|:-:|:-:|:-:|--:|
| Paseo | ● | ● | ● | ● | ● | ● | 100% |
| **Agents** | ● | ● | ● | ● | ○ | ● | 83% |
| Codeg | ● | ● | ?⃝ | ● | ● | ● | 83% |
| Nimbalyst | ● | ● | ● | ◐ | ● | ◐ | 83% |
| Nuphos | ?⃝ | ● | ● | ● | ● | ● | 83% |
| Paradev (was Superset) | ● | ● | ● | ● | ○ | ● | 83% |
| Orca | ○ | ● | ● | ◐ | ● | ● | 75% |
| Claude Code | ?⃝ | ● | ● | ● | ○ | ● | 67% |
| Conductor | ?⃝ | ● | ● | ● | ○ | ● | 67% |
| Emdash | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
| Happy | ?⃝ | ?⃝ | ● | ● | ● | ● | 67% |
| Helicon | ?⃝ | ● | ● | ?⃝ | ● | ● | 67% |
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
| Ace | ?⃝ | ?⃝ | ● | ?⃝ | ○ | ● | 33% |
| Agentastic | ?⃝ | ?⃝ | ● | ?⃝ | ○ | ● | 33% |
| Claude Squad | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| DockTerm | ?⃝ | ?⃝ | ?⃝ | ○ | ● | ● | 33% |
| Parallel Code | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| Sculptor | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| tuios | ?⃝ | ?⃝ | ?⃝ | ?⃝ | ● | ● | 33% |
| CodeAgentSwarm | ● | ?⃝ | ?⃝ | ?⃝ | ○ | ○ | 17% |
| VibeiDE | ?⃝ | ?⃝ | ?⃝ | ◐ | ○ | ?⃝ | 8% |

## Overall score

Each app's score in every table, and overall: its points over the 49 scored features. Sorted by the overall score.

| Rank | App | Running | Reach | Following | Reviewing | Tools | Tasks | Extensions | Organising | Overall |
|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | **Agents** | 100% | 67% | 100% | 100% | 90% | 100% | 80% | 83% | **91%** |
| 2 | GitHub Copilot | 92% | 83% | 100% | 100% | 80% | 61% | 100% | 50% | **82%** |
| 3 | Paseo | 100% | 100% | 71% | 90% | 60% | 61% | 60% | 100% | **80%** |
| 4 | Cursor | 83% | 67% | 86% | 100% | 80% | 67% | 80% | 50% | **76%** |
| 5 | Claude Code | 67% | 83% | 79% | 80% | 70% | 67% | 80% | 67% | **73%** |
| 5 | Nimbalyst | 83% | 83% | 86% | 70% | 70% | 50% | 70% | 83% | **73%** |
| 7 | Codeg | 100% | 67% | 64% | 90% | 60% | 67% | 40% | 83% | **71%** |
| 7 | Orca | 75% | 67% | 71% | 80% | 70% | 72% | 60% | 75% | **71%** |
| 9 | Agentastic | 100% | 42% | 79% | 90% | 80% | 67% | 80% | 33% | **70%** |
| 10 | Paradev (was Superset) | 75% | 42% | 71% | 70% | 60% | 72% | 80% | 83% | **69%** |
| 11 | OpenAI Codex | 67% | 83% | 71% | 70% | 40% | 67% | 80% | 67% | **68%** |
| 11 | Warp | 83% | 58% | 86% | 60% | 70% | 67% | 70% | 50% | **68%** |
| 13 | T3 Code | 83% | 92% | 64% | 80% | 80% | 39% | 40% | 67% | **66%** |
| 13 | Threadlines | 83% | 67% | 71% | 100% | 40% | 50% | 60% | 67% | **66%** |
| 15 | Pragma | 75% | 83% | 57% | 60% | 60% | 50% | 60% | 50% | **61%** |
| 16 | Nuphos | 83% | 58% | 79% | 70% | 40% | 44% | 20% | 83% | **60%** |
| 17 | Happy | 92% | 100% | 64% | 30% | 20% | 33% | 40% | 67% | **56%** |
| 18 | Emdash | 83% | 33% | 57% | 70% | 70% | 33% | 40% | 67% | **55%** |
| 19 | Maestro | 50% | 50% | 57% | 50% | 60% | 56% | 60% | 50% | **54%** |
| 20 | Parallel Code | 67% | 75% | 79% | 60% | 20% | 56% | 20% | 33% | **53%** |
| 21 | Conductor | 75% | 25% | 43% | 80% | 40% | 50% | 10% | 67% | **49%** |
| 22 | Rove | 67% | 33% | 29% | 60% | 20% | 61% | 40% | 50% | **46%** |
| 23 | Atelier (was Acepe) | 50% | 8% | 71% | 60% | 60% | 33% | 20% | 50% | **44%** |
| 23 | CodeAgentSwarm | 67% | 58% | 36% | 30% | 30% | 39% | 80% | 17% | **44%** |
| 25 | tuios | 83% | 33% | 50% | 60% | 20% | 33% | 30% | 33% | **43%** |
| 25 | Vibe Kanban | 67% | 50% | 29% | 60% | 30% | 28% | 20% | 67% | **43%** |
| 27 | Sculptor | 58% | 33% | 29% | 80% | 20% | 33% | 20% | 33% | **38%** |
| 28 | Roamgate | 67% | 50% | 29% | 80% | 20% | 11% | 0% | 50% | **37%** |
| 29 | Ace | 33% | 17% | 57% | 20% | 40% | 11% | 40% | 33% | **31%** |
| 30 | Helicon | 42% | 33% | 29% | 20% | 0% | 6% | 40% | 67% | **29%** |
| 30 | VibeiDE | 50% | 50% | 29% | 40% | 30% | 11% | 20% | 8% | **29%** |
| 32 | DockTerm | 17% | 33% | 50% | 20% | 40% | 0% | 20% | 33% | **26%** |
| 33 | ReevesAgents | 33% | 17% | 29% | 0% | 20% | 22% | 0% | 50% | **22%** |
| 34 | Claude Squad | 50% | 0% | 14% | 20% | 20% | 0% | 0% | 33% | **16%** |

## Sources for leases, waits, workflows in the repository and live documents

These four features were added on 2026-10-15 (#1094), each researched from the app's own
docs, changelog, README and, where open, code (a search of a shallow clone of the default
branch). A link on a ○ for an open-source app is the repository whose code has no such
thing. A ?⃝ has no link: the app's docs did not say.

- **Agents:** Leases ● ([source](../explanation/leases.md)); Waits ● ([source](../how-to/wait-for-something.md)); Workflows in the repository ● ([source](../how-to/set-up-a-workflow.md)); Live documents ● ([source](../how-to/follow-a-live-document.md)).
- **Agentastic:** Leases ?⃝; Waits ?⃝; Workflows in the repository ○ ([source](https://www.agentastic.com/docs/advanced/task-scheduler)); Live documents ?⃝.
- **Ace:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **Atelier (was Acepe):** Leases ○ ([source](https://github.com/flazouh/atelier)); Waits ○ ([source](https://github.com/flazouh/atelier)); Workflows in the repository ○ ([source](https://github.com/flazouh/atelier)); Live documents ◐ ([source](https://github.com/flazouh/atelier/blob/HEAD/docs/app.md)).
- **Claude Code:** Leases ?⃝; Waits ◐ ([source](https://code.claude.com/docs/en/tools-reference)); Workflows in the repository ● ([source](https://code.claude.com/docs/en/github-actions)); Live documents ?⃝.
- **Claude Squad:** Leases ○ ([source](https://github.com/smtg-ai/claude-squad)); Waits ○ ([source](https://github.com/smtg-ai/claude-squad)); Workflows in the repository ○ ([source](https://github.com/smtg-ai/claude-squad)); Live documents ○ ([source](https://github.com/smtg-ai/claude-squad/blob/HEAD/README.md)).
- **CodeAgentSwarm:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **Codeg:** Leases ○ ([source](https://github.com/spacering-net/codeg)); Waits ○ ([source](https://github.com/spacering-net/codeg)); Workflows in the repository ○ ([source](https://github.com/spacering-net/codeg/blob/HEAD/src-tauri/src/db/entities/automation.rs)); Live documents ?⃝.
- **Conductor:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **Cursor:** Leases ?⃝; Waits ?⃝; Workflows in the repository ● ([source](https://cursor.com/docs/cli/github-actions)); Live documents ● ([source](https://cursor.com/help/ai-features/agent)).
- **DockTerm:** Leases ○ ([source](https://github.com/munvard/dockterm)); Waits ○ ([source](https://github.com/munvard/dockterm)); Workflows in the repository ○ ([source](https://github.com/munvard/dockterm)); Live documents ?⃝.
- **Emdash:** Leases ○ ([source](https://github.com/generalaction/emdash)); Waits ○ ([source](https://github.com/generalaction/emdash)); Workflows in the repository ○ ([source](https://github.com/generalaction/emdash)); Live documents ?⃝.
- **GitHub Copilot:** Leases ?⃝; Waits ?⃝; Workflows in the repository ◐ ([source](https://github.blog/changelog/2026-06-11-github-agentic-workflows-is-now-in-public-preview/)); Live documents ● ([source](https://code.visualstudio.com/docs/agents/run/review-code-edits)).
- **Happy:** Leases ○ ([source](https://github.com/slopus/happy)); Waits ○ ([source](https://github.com/slopus/happy)); Workflows in the repository ○ ([source](https://github.com/slopus/happy/blob/HEAD/docs/roadmap.md)); Live documents ?⃝.
- **Helicon:** Leases ○ ([source](https://github.com/HarjjotSinghh/helicon)); Waits ◐ ([source](https://github.com/HarjjotSinghh/helicon/blob/HEAD/docs/CHANGELOG.md)); Workflows in the repository ○ ([source](https://github.com/HarjjotSinghh/helicon)); Live documents ?⃝.
- **Maestro:** Leases ○ ([source](https://github.com/RunMaestro/Maestro)); Waits ○ ([source](https://github.com/RunMaestro/Maestro)); Workflows in the repository ● ([source](https://github.com/RunMaestro/Maestro/blob/HEAD/docs/maestro-cue-configuration.md)); Live documents ?⃝.
- **Nimbalyst:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ● ([source](https://nimbalyst.com/docs/visual-editors-powered-by-ai/markdown-wysiwyg/ai-editing-red-green-diff-approval/)).
- **Nuphos:** Leases ○ ([source](https://github.com/nuphos/nuphos)); Waits ○ ([source](https://github.com/nuphos/nuphos)); Workflows in the repository ○ ([source](https://github.com/nuphos/nuphos)); Live documents ?⃝.
- **Orca:** Leases ○ ([source](https://github.com/stablyai/orca)); Waits ◐ ([source](https://www.onorca.dev/docs/cli/orchestration)); Workflows in the repository ○ ([source](https://www.onorca.dev/docs/model/orca-yaml)); Live documents ◐ ([source](https://www.onorca.dev/docs/editing/file-explorer)).
- **OpenAI Codex:** Leases ?⃝; Waits ?⃝; Workflows in the repository ● ([source](https://developers.openai.com/codex/github-action)); Live documents ?⃝.
- **Paradev (was Superset):** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **Parallel Code:** Leases ○ ([source](https://github.com/johannesjo/parallel-code)); Waits ◐ ([source](https://github.com/johannesjo/parallel-code/blob/HEAD/docs/design-doc.md)); Workflows in the repository ○ ([source](https://github.com/johannesjo/parallel-code)); Live documents ● ([source](https://github.com/johannesjo/parallel-code/blob/HEAD/docs/document-workspaces.md)).
- **Paseo:** Leases ○ ([source](https://github.com/getpaseo/paseo)); Waits ◐ ([source](https://github.com/getpaseo/paseo/blob/HEAD/public-docs/mcp.md)); Workflows in the repository ● ([source](https://github.com/getpaseo/paseo/blob/HEAD/public-docs/hub/configuration/hub-yml.md)); Live documents ?⃝.
- **Pragma:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **ReevesAgents:** Leases ○ ([source](https://github.com/mertkayacs/reevesagents)); Waits ○ ([source](https://github.com/mertkayacs/reevesagents)); Workflows in the repository ○ ([source](https://github.com/mertkayacs/reevesagents)); Live documents ○ ([source](https://github.com/mertkayacs/reevesagents)).
- **Roamgate:** Leases ○ ([source](https://github.com/powerfooI/roamgate)); Waits ○ ([source](https://github.com/powerfooI/roamgate)); Workflows in the repository ○ ([source](https://github.com/powerfooI/roamgate)); Live documents ○ ([source](https://github.com/powerfooI/roamgate)).
- **Rove:** Leases ○ ([source](https://github.com/Sma1lboy/rove)); Waits ○ ([source](https://github.com/Sma1lboy/rove)); Workflows in the repository ○ ([source](https://github.com/Sma1lboy/rove)); Live documents ○ ([source](https://github.com/Sma1lboy/rove)).
- **Sculptor:** Leases ○ ([source](https://github.com/imbue-ai/sculptor)); Waits ◐ ([source](https://github.com/imbue-ai/sculptor/blob/HEAD/agent_docs/scu-1776-pi-wake-serialization/design.md)); Workflows in the repository ○ ([source](https://github.com/imbue-ai/sculptor)); Live documents ?⃝.
- **T3 Code:** Leases ○ ([source](https://github.com/pingdotgg/t3code)); Waits ◐ ([source](https://github.com/pingdotgg/t3code/blob/HEAD/docs/user/source-control.md)); Workflows in the repository ○ ([source](https://github.com/pingdotgg/t3code/blob/HEAD/docs/user/project-settings.md)); Live documents ◐ ([source](https://github.com/pingdotgg/t3code/blob/HEAD/apps/web/src/components/files/FilePreviewPanel.tsx)).
- **Threadlines:** Leases ○ ([source](https://github.com/Threadlines/threadlines)); Waits ◐, Claude's own check-backs alone ([source](https://github.com/Threadlines/threadlines/releases/tag/v0.7.1)); Workflows in the repository ○ ([source](https://github.com/Threadlines/threadlines)); Live documents ?⃝.
- **tuios:** Leases ○ ([source](https://github.com/Gaurav-Gosain/tuios)); Waits ◐ ([source](https://github.com/Gaurav-Gosain/tuios/blob/HEAD/docs/AGENT_STATE.md)); Workflows in the repository ○ ([source](https://github.com/Gaurav-Gosain/tuios)); Live documents ○ ([source](https://github.com/Gaurav-Gosain/tuios)).
- **Vibe Kanban:** Leases ○ ([source](https://github.com/BloopAI/vibe-kanban)); Waits ○ ([source](https://github.com/BloopAI/vibe-kanban)); Workflows in the repository ○ ([source](https://github.com/BloopAI/vibe-kanban)); Live documents ?⃝.
- **VibeiDE:** Leases ?⃝; Waits ?⃝; Workflows in the repository ?⃝; Live documents ?⃝.
- **Warp:** Leases ?⃝; Waits ?⃝; Workflows in the repository ● ([source](https://docs.warp.dev/agent-platform/cloud-agents/integrations/github-actions)); Live documents ◐ ([source](https://docs.warp.dev/agent-platform/capabilities/planning)).

## The apps

- **Agents:** this project. Mac window, Remote on iPhone and iPad, web page, and agentsd hosts.
- **[Agentastic](https://www.agentastic.dev/):** A closed-source native Mac IDE for many agents, with an iPhone companion and cloud agents.
- **[Ace](https://useace.dev):** A closed-source native app for Claude Code, Cursor and its own agent, on Mac, Windows and Linux, from the maker of Atelier. Its row is filled from its release notes ([flazouh/ace-releases](https://github.com/flazouh/ace-releases/releases)). Since 0.1.53 it is Sessions and Code only: the Browser, Git, Tasks, Usage and Marketplace pages are gone "for now".
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
- **[Orca](https://github.com/stablyai/orca):** An open-source (MIT) desktop app for Mac, Windows and Linux running many CLI agents side by side, a worktree each, with terminals, a browser the agents drive, pull requests, SSH and self-hosted Orca servers, and a beta phone companion.
- **[Paradev (was Superset)](https://paradev.com):** A desktop app for parallel agents with its own task tracker, cloud workspaces, plugins and an iPhone app; renamed from Superset on 2026-10-26 ([changelog](https://paradev.com/changelog)). Its Mobile pane for simulators and emulators is off "for now" since desktop 1.40.
- **[Parallel Code](https://github.com/johannesjo/parallel-code):** A desktop app with tiled tasks, Docker sandboxes and an Android app.
- **[Paseo](https://github.com/getpaseo/paseo):** An open-source daemon with desktop, iOS, Android, web and CLI clients.
- **[Pragma](https://pragma-app.sh):** A desktop app with a task board, SSH remote projects and the Pragma Go mobile client.
- **[ReevesAgents](https://github.com/mertkayacs/reevesagents):** TUI, local web UI and CLI running agent CLIs in tmux, with an MCP so one agent steers the others.
- **[Roamgate](https://github.com/powerfooI/roamgate):** A web/PWA client for a Herdr terminal-multiplexer server.
- **[Rove](https://github.com/Sma1lboy/rove):** A terminal app with a worktree per task, a daemon, a local kanban and iOS/Android bridges.
- **[Sculptor](https://github.com/imbue-ai/sculptor):** Imbue's desktop app for parallel agents, with a container backend and a CI babysitter.
- **[T3 Code](https://github.com/pingdotgg/t3code):** A local server driven from desktop, web, iOS and Android apps.
- **[Threadlines](https://github.com/Threadlines/threadlines):** A T3 Code fork: desktop and Docker-server workspace, a worktree per thread.
- **[tuios](https://github.com/Gaurav-Gosain/tuios):** A terminal multiplexer and tiling window manager with an agent-state rail and Inbox.
- **[Vibe Kanban](https://github.com/BloopAI/vibe-kanban):** A local web app whose kanban was retired in v0.1.44; the README says it is sunsetting.
- **[VibeiDE](https://vibeide.dev):** A paid, closed-source desktop app with task queues per project.
- **[Warp](https://docs.warp.dev/agent-platform/):** An agentic terminal with the Oz cloud-agent platform.
