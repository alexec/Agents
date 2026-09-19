# Agents

A Mac app, rebuilt one feature at a time against a written spec.

## Build and run

```sh
xcodegen generate      # regenerate Agents.xcodeproj after editing project.yml
open Agents.xcodeproj
```

From the command line:

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' build
swift test --package-path Packages/AgentsKit
```

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

# By hand, without the app
./build/DD/Build/Products/Debug/Agents.app/Contents/Helpers/agentsd
```

Nothing is stored anywhere else, and the daemon is the only writer. To start again from
nothing, quit the app, `pkill -f agentsd`, and delete that directory.

## How work happens here

Spec Kit, one feature at a time. Each feature is a folder under `specs/`:

1. `/speckit-specify` — what the feature is, in the user's words, with acceptance criteria.
2. `/speckit-clarify` — the ambiguities get answered before any design.
3. `/speckit-plan` — how it will be built.
4. `/speckit-tasks` — the ordered list.
5. `/speckit-implement` — the work, against those tasks.

The rules the specs are held to are in `.specify/memory/constitution.md`.
