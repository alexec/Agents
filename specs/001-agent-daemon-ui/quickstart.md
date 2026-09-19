# Quickstart: proving the feature works

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Each section is a thing to run and what should happen. The first three need nothing installed beyond
the repository; the last two use the real runtimes and the user's own credentials.

## Prerequisites

```sh
xcodegen generate
swift build --package-path Packages/AgentsKit
```

For the live sections: `copilot`, `grok` and `node`/`npx` on the login shell's PATH, each signed in.
Check with `copilot --acp`, `grok agent stdio` and `npx -y @agentclientprotocol/claude-agent-acp`:
each should sit there waiting for JSON rather than exiting.

## 1. The unit and integration suite

```sh
swift test --package-path Packages/AgentsKit
```

Runs against `FakeACPAgent`, needs no network, no credentials and no Xcode. It must cover, at least:

- Every transition in the state machine, including the ones that must not happen (nothing reaches
  `archived` without the user; `finished` is reachable only by `endTurn`).
- A transcript appended entry by entry, reread after a simulated crash, and still in order.
- `session/load` replay being discarded without duplicating the transcript.
- A permission request held while no client is connected, answered later, with the agent still alive.
- The daemon's exit rule: it exits with nothing in hand, and does not exit while a permission waits.

## 2. The daemon outlives its window

```sh
swift test --package-path Packages/AgentsKit --filter DaemonSurvival
```

Starts a daemon, starts a fake agent on a long turn, kills the client connection, and proves the
agent is still running and still recording. Then reconnects and proves the new client sees
everything produced while nothing was connected. This is SC-002 and the reason the daemon exists.

## 3. The app, by hand

```sh
open Agents.xcodeproj    # ⌘R
```

- The window opens on an empty list that says how to start the first agent, not an error.
- Every runtime found on this Mac is listed. Any that is missing says where we looked.
- Start an agent in a scratch folder with "create a file called hello.txt saying hello". It appears
  as running within a couple of seconds and its output appears without touching anything.
- Force quit the app (⌥⌘Esc) while it works. `pgrep -fl copilot` still shows the process, the file
  still appears, and reopening the app shows the agent with everything it said while the app was gone.

## 4. One code path, three runtimes

```sh
AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter Live
```

For each of claude, grok and copilot, against the real CLI:

- `initialize` and `session/new` succeed and the advertised `configOptions` are returned.
- A trivial prompt reaches `end_turn`.
- The process is killed, the session is picked up again by resume or load as that runtime advertises,
  and the reply from before the kill is still there.
- No code in the test, and no code it calls, branches on the runtime's name.

Expect this to cost a few pennies of the user's credit and to take a minute. It is off by default for
exactly that reason.

## 5. The things only a person can check

- A permission question arrives while the app is shut, and is the first thing on screen when it
  opens, with the agent still waiting.
- Ten agents at once: the list and a transcript still scroll smoothly (SC-006).
- Stop an agent, restart the Mac, open the app, send it a follow-up. It answers knowing what it knew
  before (SC-011).
- Starting a Claude agent for the first time, when npm has to fetch the adapter, reads as the runtime
  starting rather than as the app hanging.

## When it is done

Every acceptance scenario in [spec.md](./spec.md) has something above that exercises it, section 1
and 2 pass with no network, and sections 3 to 5 have been done by hand at least once on this Mac.
