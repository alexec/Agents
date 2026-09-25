# Agents

A Mac app, rebuilt one feature at a time against a written spec.

Using the app? The docs are at https://alexec.github.io/Agents/ (source in `docs/`;
preview with `scripts/docs.sh serve`). This README is for building and working on it.

The window is a list of the projects you work in — a project is a folder, named by that
folder — with that project's agents beside it in three groups: what needs you, what is
working, what is done. Each project also has a lead: one agent whose job is the project
rather than a task, which can start the others, brief them, read how they got on, and
stop one that has gone wrong, asking you before each move.

## Build and run

```sh
xcodegen generate      # regenerate Agents.xcodeproj after editing project.yml
open Agents.xcodeproj
```

From the command line:

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

`-skipPackagePluginValidation` is needed because SwiftTerm ships a build-tool plug-in,
and Xcode will not run one from the command line until it has been trusted. Xcode itself
asks once and remembers; `xcodebuild` has nobody to ask, and fails with three unexplained
build commands instead.

## The daemon

The app is a window. The agents belong to a helper, `agentsd`, which lives inside the app
bundle at `Contents/Helpers/agentsd` and is started by the app in a session of its own, so
agents keep working when the window is gone. There is no login item and nothing to install.

It exits by itself once it is holding no agents and no window is connected.

```sh
# Is it running?
pgrep -fl agentsd

# Everything it owns
ls ~/Library/Application\ Support/Agents/
#   daemon.sock   the app connects here
#   daemon.lock   flock, held by the one daemon
#   daemon.log    what it has been doing
#   agents/<uuid>/agent.json        the record, written whole on every change
#   agents/<uuid>/transcript.jsonl  appended as things happen, never rewritten
#   projects.json                   only what a folder cannot tell us: archived, added

# By hand, without the app
./build/DD/Build/Products/Debug/Agents.app/Contents/Helpers/agentsd
```

Nothing is stored anywhere else, and the daemon is the only writer. To start again from
nothing, quit the app, `pkill -f agentsd`, and delete that directory.

## A second copy, beside the first

That directory is also the daemon's identity: the lock it holds, the socket it answers
on and the agents it owns all hang off it. Point a window at a different one and it is a
different daemon, with its own agents, which is how a build from a branch is run beside
the ordinary app without either disturbing the other.

```sh
open -n path/to/Agents.app --args --root /tmp/agents-branch
```

`--root` first, `AGENTS_ROOT` second, and the ordinary place when neither is given.
`--root` exists because it is what survives `open`: macOS passes a second copy of a
bundle its arguments and not its environment. The window hands the path to the daemon it
starts, and that daemon hands it to every MCP helper it gives an agent, so the whole
chain agrees without anybody guessing.

The window says which one it is in the title of its projects column, when it is not the
ordinary one. Keep the path short: a Unix socket may be named with 104 bytes and no
more, and a root nested a few folders deep will say so rather than fail quietly.

That is also how an agent working on this repository tries its own change: the `run-app`
skill under `.claude/skills` builds, launches a copy on a root of its own, drives it over
that root's socket — every method the window has — screenshots the window without taking
the screen off you, and stops the window and its daemon afterwards. Nothing it does
reaches the agents you are running.

## What the app does with a runtime

Everything the protocol defines, decided by what each runtime advertises rather than by
which runtime it is.

Four runtimes are known: Claude, Grok, Copilot and Cursor. Three are commands of their own
and Claude is an npm package run through your Node, because `claude` has no ACP flag. What
the app starts for Cursor is `cursor-agent`, not `agent`, which belongs to Grok.

No code in the app asks which runtime it is talking to. A runtime that advertises a thing
gets that thing, and one that does not, does not: Cursor offers no options to pick from and
no way to sign out, so the app shows neither.

- **Attachments.** Drag a file onto the prompt, paste a screenshot, or type `@` and pick
  a file. A picture goes by value where the runtime takes pictures and by reference
  otherwise, and an attachment a runtime cannot take is refused before the prompt is sent.
- **The work, shown.** Edits arrive as diffs where the runtime sends them, command output
  arrives as output, and files a tool call touched open at their line.
- **A file, shown.** The agent can ask for a file to be put in front of you, at a line,
  and it opens in the files pane beside the conversation. The same MCP server carries
  this as carries the suggestions below, and the same rule applies as to everything
  else an agent reaches for: inside the folders it was given, or refused. A request for
  a conversation you are not reading waits until you open it rather than taking the
  window off you. A Markdown file opens as a page that follows the agent's edits and
  can be typed on, and what you type is told to the agent on its next turn.
- **Cost and context.** A meter follows the turn, and what each turn used goes on the
  record. Cost is shown as the runtime reported it, per currency, never estimated.
- **Serving the agent.** The app reads and writes files on an agent's behalf and runs
  commands for it. Reads are recorded; writes go through the same permission question any
  other change does; nothing may reach outside the folders the agent was given. Grok is
  the runtime that uses this today, and only because the app says it can.
- **Signing in.** A runtime that is installed and not signed in can be signed into from
  the app, or, where the runtime insists on a terminal, it hands over the exact command.
  A command the app puts in front of you is one it knows it would start. What a runtime
  says about itself in prose is shown, but never followed: Cursor's sign-in text says to
  run `agent login`, and `agent` here is Grok.
- **Conversations the app did not start.** The runtime's own list, ready to be picked up,
  branched, or deleted with a confirmation.
- **What to ask next.** When a turn ends the agent may offer a few things you might want
  to say, shown as buttons above the prompt. Tapping one fills the prompt and leaves it
  to you to send. ACP has no way to carry a suggestion, so the app serves the agent an
  MCP server with this and `show_file` on it, attached to every session. Offering the tool
  is not enough on its own — none of the three called it unasked — so the daemon adds a
  line to each prompt asking for them. That line goes to the runtime and not into the
  transcript, which still records what you said. Copilot has a follow-up feature of its
  own and uses that instead.

To check what each runtime advertises against what the app does with it:

```sh
./scripts/acp-handshake.sh
```

## Scoping an agent's tools

Every runtime arrives holding its own version of nearly everything this app owns: a way to
schedule something, a way to raise a question, a way to start another agent, somewhere to
put what it wrote. Used, they put the work somewhere the app cannot see — a cron entry with
no row in the project, a question in a queue that never reaches your phone, a report in a
document nobody agreed on. So for the sessions the app starts, those tools are taken away,
and the app's own are all that is left.

Nothing of yours changes. No file in your home directory is read as configuration or
written, and nothing is left behind when the app is not running: the same runtime started
from your terminal a minute later has everything it always had.

How it is asked for depends on what each runtime offers, and it is a table rather than a
condition — `ToolPolicyCatalog` is the one place that knows. Claude takes a denial list on
the session and loses fifteen built-ins and two connectors. Copilot takes flags at launch
and loses its subagents, its session store and the whole rival MCP server that duplicated
this app's remit. Grok takes an allow list on the session, plus a config overlay the app
writes under its own root. Cursor has no lever at all, so its three conflicting tools stay
— and are named in the briefing instead, along with what to use in their place.

Nothing the work needs is touched: reading, searching, editing, writing, running commands,
planning and keeping a to-do list stay, and so does the question tool each runtime raises
an escalation through — the one thing here it would matter most to break.

To re-ask every runtime what it has today, and see anything the policy does not account
for:

```sh
./scripts/runtime-tools.sh
```

## How work happens here

Spec Kit, one feature at a time. Each feature is a folder under `specs/`:

1. `/speckit-specify` — what the feature is, in the user's words, with acceptance criteria.
2. `/speckit-clarify` — the ambiguities get answered before any design.
3. `/speckit-plan` — how it will be built.
4. `/speckit-tasks` — the ordered list.
5. `/speckit-implement` — the work, against those tasks.

Every spec has a Docs section listing the pages on the docs site it adds or changes, and
`scripts/docs.sh check` runs on every push, so the docs move with the code.

The rules the specs are held to are in `.specify/memory/constitution.md`.
