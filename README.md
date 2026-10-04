# Agents

Keep your editor and your coding agent. Agents runs several agents at once, shows which
one needs you, lets them work together and on their own, and lets you answer them from
your phone. [Why Agents](https://alexec.github.io/Agents/explanation/why-agents/)

A Mac app, rebuilt one feature at a time against a written spec.

Using the app? The docs are at https://alexec.github.io/Agents/ (source in `docs/`;
preview with `scripts/docs.sh serve`). This README is for building and working on it.

The window is a list of the projects you work in — a project is a folder, named by that
folder, on this Mac or on a Linux server — with that project's agents beside it, grouped
by what happens next: needs you, waiting, working, done, paused, parked. Unread finished
sessions need you until you open them. An agent can start helpers of its own (three running and five kept per project unless you change it),
and a project's workflows (Markdown files under `.agents/workflows/`) start agents
by themselves on a schedule or when something happens.

## Setting it up

On a Mac, Agents is two apps:

- **Agents**, the window, built for the App Store. It runs in the sandbox and starts
  nothing: it is a screen onto your agents, as the iPhone and iPad app is.
- **Agents Host**, a download signed by us and installed outside the App Store. It runs
  this Mac's agents, and optionally the control plane every window, phone and server
  connects to, kept running by macOS.

Beside the window and the iPhone and iPad app, Agents Host serves Agents as a web page for
a browser on this Mac, at `http://localhost:8792`. **View ▸ Open in Browser** in the window,
or **Open in Browser** in Agents Host, opens it and pairs that browser the first time. See
[Use Agents in a browser](https://alexec.github.io/Agents/how-to/use-agents-in-a-browser/).

The control plane is yours: on your Mac through Agents Host, or as several copies of
`agents-control` in containers on hosting you rent, sharing an S3-compatible bucket. A
Linux server becomes a host by running one command the window shows. See
[Set up Agents on this Mac](https://alexec.github.io/Agents/how-to/set-up-on-this-mac/)
and [The control plane](https://alexec.github.io/Agents/explanation/control-plane/).

Neither app is in the App Store yet, so today both are built from source.

## Build and run

```sh
xcodegen generate      # regenerate Agents.xcodeproj after editing project.yml
open Agents.xcodeproj
```

The schemes:

| Scheme | What it builds |
|---|---|
| `AgentsStore` | the App Store window: sandboxed, no helpers, reaches everything through a control plane |
| `AgentsHost` | Agents Host, carrying `agentsd`, `agents-control` and `agents-relay` |
| `Remote` | the iPhone and iPad app |

The web page lives in `Web/`: Preact and TypeScript, bundled by esbuild. Its build,
`Web/dist`, is checked in with a `MANIFEST` of hashes, and Agents Host carries it, so
building Agents needs no Node. So are its protocol types, `Web/src/protocol/generated.ts`,
generated from the Swift source. Only changing the web app, or a protocol type in Swift,
needs anything more, and `scripts/web.sh` does it:

```sh
scripts/web.sh types   # regenerate the TypeScript types after changing a DaemonAPI type
scripts/web.sh build   # rebuild Web/dist after changing Web/ (needs the Node in Web/.node-version)
scripts/web.sh check   # what CI checks: types fresh, dist matching its manifest, and with Node, the tests
```

A test fails, in Swift as well as in Node, when `Web/dist` or `generated.ts` is out of
date with its source.

From the command line:

```sh
xcodebuild -scheme AgentsStore -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme AgentsHost -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
swift test --package-path Packages/ControlPlane
```

Build the schemes one after another, not at once. The Linux programs are cross-built on
the Mac, with the swift.org toolchain and Static Linux SDK that match Xcode's Swift:
`scripts/build-linux-agentsd.sh` for a server's host, and `scripts/build-linux-control.sh`
for the control plane's container. `deploy/` runs three copies of the control plane over
MinIO behind Caddy, for trying it out; see `deploy/README.md`.

`-skipPackagePluginValidation` is needed because SwiftTerm ships a build-tool plug-in,
and Xcode will not run one from the command line until it has been trusted. Xcode itself
asks once and remembers; `xcodebuild` has nobody to ask, and fails with three unexplained
build commands instead.

A Swift warning in this repository's own code fails the build: the Xcode targets set
`SWIFT_TREAT_WARNINGS_AS_ERRORS`, and each package's Swift targets
`.treatAllWarnings(as: .error)`. Fix the warning rather than silencing it. The generated
tree-sitter C grammars are the exception, and stay quiet with `-w`.

## The daemon

The window runs nothing. The agents belong to a helper, `agentsd`, which is a host of the
control plane. Agents Host carries it at `Contents/Helpers/agentsd` and registers it with
macOS as a launch agent, so it runs with every window closed, starts at login, and never
exits for being idle. On a Linux server the same daemon lives in `~/.agents-server`.

The rest of this section is about the root every daemon keeps.

```sh
# Is it running? (Agents Host's launch agent)
launchctl print gui/$(id -u)/com.alexecollins.agentshost.daemon | grep -E 'state|pid'

# Everything it owns
ls ~/Library/Application\ Support/Agents/
#   daemon.sock   agents' own tools connect here (agentsd mcp)
#   daemon.lock   flock, held by the one daemon
#   daemon.log    what it has been doing
#   agents/<uuid>/agent.json        the record, written whole on every change
#   agents/<uuid>/transcript.jsonl  appended as things happen, never rewritten
#   projects.json                   only what a folder cannot tell us: archived, added

# By hand, as a host of a control plane, on a root of its own
AGENTS_ROOT=/tmp/agents-branch "./build/DD-host/Build/Products/Debug/Agents Host.app/Contents/Helpers/agentsd" \
  --control-code '<host code>'
```

Nothing is stored anywhere else, and the daemon is the only writer. To start again from
nothing, stop Agents Host's jobs (its window's Stop, or `launchctl bootout` of both), and
delete that directory.

## A second copy, beside the first

That directory is also the daemon's identity: the lock it holds, the socket it answers
on and the agents it owns all hang off it. Point a host at a different one
(`AGENTS_ROOT`) and it is a different host, with its own agents. Give it a control plane
of its own too (`agents-control serve --home <folder>`, with `AGENTS_CONTROL_URL` and
`--port`), pair a window with that one, and a build from a branch runs beside the
ordinary set-up without either disturbing the other.

Keep the path short: a Unix socket may be named with 104 bytes and no more, and a root
nested a few folders deep will say so rather than fail quietly.

That is also how an agent working on this repository tries its own change: the `run-app`
skill under `.agents/skills` (linked from `.claude/skills`) builds, starts a control plane
and a host on a root of its own, pairs a window with them (its pairing kept apart from
yours with `--walk`), drives the host over that root's socket — every method the window
has — screenshots the window without taking the screen off you, and stops all three
afterwards. Nothing it does reaches the agents you are running.

## What the app does with a runtime

Everything the protocol defines, decided by what each runtime advertises rather than by
which runtime it is.

Eight runtimes are known: Claude, Codex, Gemini, Antigravity, OpenCode, Grok, Copilot and Cursor.
Grok, Copilot and Cursor are commands of their own that you install. Claude is an npm
adapter, because `claude` has no ACP flag, run through your Node or installed in the app's
own folder. Codex, Gemini, Antigravity and OpenCode are only ever the app's own copies,
installed from the set-up sheet or **Settings ▸ Agent Runtimes**. What the app starts for
Cursor is `cursor-agent`, not `agent`, which belongs to Grok, and an `opencode` on the PATH is
never looked up: two unrelated programs share that name.

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
- **Steering.** Where a runtime advertises `_meta.steering` (the Claude adapter and
  codex-acp do), a prompt queued behind a running turn offers **Send now**, which goes in
  through `_session/steering` rather than waiting for the turn to end.
- **Background work.** The app opts in to JetBrains AIR's `asyncTasks` and
  `nativeSubagentSessions`, so a runtime's background shells and subagents are listed over
  the prompt, each shell with **Stop**, and a subagent's steps have a pane of their own.
  What still runs when the runtime is let go ends with the turn.
- **Notices, providers and vendor extensions.** Session notices are drawn in the chat;
  a provider the runtime does not mark required can be turned off; `_auth/status_update`
  says which account a runtime is signed in with; Cursor's `cursor/update_todos` becomes
  the plan and its `ask_question` a form card. An extension request the app does not know
  is refused and logged.
- **Conversations the app did not start.** The runtime's own list, ready to be picked up,
  branched, or deleted with a confirmation.
- **What to ask next.** When a turn ends the agent may offer a few things you might want
  to say, shown as buttons above the prompt. Tapping one fills the prompt and leaves it
  to you to send. ACP has no way to carry a suggestion, so the app serves the agent an
  MCP server with this and `show_file` on it, attached to every session. Offering the tool
  is not enough on its own — runtimes do not call it unasked — so the daemon adds a
  line to each prompt asking for them. That line goes to the runtime and not into the
  transcript, which still records what you said. Copilot has a follow-up feature of its
  own and uses that instead.

To check what each runtime advertises against what the app does with it:

```sh
./scripts/acp-handshake.sh            # every runtime
./scripts/acp-handshake.sh claude     # one of them
```

The **Nightly runtime check** workflow (`.agents/workflows/nightly-runtimes.md`, #39) does
this, and more, for each runtime with a new release: `scripts/nightly-runtimes.py` re-pins
it in a tree of its own, builds Agents Host, runs the AgentsKit runtime tests, the
handshake and the tools check, and has one real turn through a scratch `agentsd` on the
cheapest model the runtime offers. A pinned runtime that passes becomes a pull request on
`nightly/runtime-<id>`; one that fails becomes an issue naming the step. It tests on this
Mac's `main` and runs the same build and tests on `main` unchanged: what already fails there
is listed as "already failing on main" and filed for no runtime, and runtimes that fail for
one cause share one issue. A runtime with
nothing new, or out of the pool, costs nothing. It arrives waiting for your OK: turn it
off first (**Turn Off** on its row), then **Approve**, and turn it on when you want it.
To try it without opening anything:

```sh
./scripts/nightly-runtimes.py plan --home /tmp/nightly --runtimes claude
./scripts/nightly-runtimes.py build --home /tmp/nightly     # lease "build" around this one
./scripts/nightly-runtimes.py check --home /tmp/nightly
./scripts/nightly-runtimes.py report --home /tmp/nightly --dry-run
```

Two weekly reviews (#42) look for new problems in what changed on `main` since their last
run, plus one area in rotation, and have the critical and high findings fixed by helper
agents on branches of their own (failing test first, proven, left unmerged for you):

- **Security review** (`.agents/workflows/security-review.md`), Sundays at 03:00: the
  `security-review` skill's method, rotating through tokens, daemon.sock roles, servers,
  files from someone else, git hooks, the Keychain and logs. At most two helpers a run.
- **Performance review** (`.agents/workflows/performance-review.md`), Wednesdays at 03:00:
  main-thread work, unbounded growth, file descriptors, polling, transcript size,
  start-up and reconnects. At most one helper a run, whose proof is six runs of the
  measurement on `main` and six on its branch.

Each keeps its findings, and the commit of `main` it reviewed through, in its own folder,
`.agents/reviews/security/` or `.agents/reviews/performance/`, on a local branch that is
never pushed (`agents/reviews-security`, `agents/reviews-performance`): a security
finding is not published before it is fixed. Both arrive turned off; **Run now** tries one.

**Free disk space** (`.agents/workflows/free-disk-space.md`, #199) runs on `mac.disk_low`. It
deletes build output (the folders `.gitignore` ignores and git tracks nothing in, such as
`build/`, `.build`, `DerivedData` and `Web/node_modules`) from the worktrees of agents that are
Done, Parked or Archived and hold no lease. At the critical level it also removes archived
agents' worktrees that have nothing uncommitted, keeping the branch. It never touches the
project folder, a worktree no session names, or a busy agent's. It too arrives turned off.

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
the session and loses fourteen built-ins and two connectors. Copilot takes flags at launch
and loses its subagents, its session store and the whole rival MCP server that duplicated
this app's remit. Grok takes an allow list on the session, plus a config overlay the app
writes under its own root. Cursor has no lever at all, so its three conflicting tools stay
— and are named in the briefing instead, along with what to use in their place. Codex
takes feature switches in a `CODEX_CONFIG` set only for its sessions, Gemini loses its
subagents and task tracker, Antigravity takes a deny list under `_meta.agy` and loses
`start_subagent`, and OpenCode takes an `OPENCODE_CONFIG_CONTENT` laid over the person's own
config that removes `task`, turns sharing and self-update off, and makes edits, commands and
web fetches ask. OpenCode's own question tool is left off, so its questions go through the
app's `ask_form`.

Nothing the work needs is touched: reading, searching, editing, writing, running commands,
planning and keeping a to-do list stay, and so does the question tool each runtime raises
an escalation through — the one thing here it would matter most to break. Nor are a
runtime's own subagents and background tasks, where the app can show them: Claude keeps
`Agent`, `TaskOutput` and `TaskStop`, and Codex runs with `multi_agent` on.

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
