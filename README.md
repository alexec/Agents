# Agents

A Mac app, rebuilt one feature at a time against a written spec.

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
  MCP server with one tool on it and attaches that to every session. Offering the tool
  is not enough on its own — none of the three called it unasked — so the daemon adds a
  line to each prompt asking for them. That line goes to the runtime and not into the
  transcript, which still records what you said. Copilot has a follow-up feature of its
  own and uses that instead.

To check what each runtime advertises against what the app does with it:

```sh
./scripts/acp-handshake.sh
```

## How work happens here

Spec Kit, one feature at a time. Each feature is a folder under `specs/`:

1. `/speckit-specify` — what the feature is, in the user's words, with acceptance criteria.
2. `/speckit-clarify` — the ambiguities get answered before any design.
3. `/speckit-plan` — how it will be built.
4. `/speckit-tasks` — the ordered list.
5. `/speckit-implement` — the work, against those tasks.

The rules the specs are held to are in `.specify/memory/constitution.md`.
