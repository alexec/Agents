# Quickstart: Proving the Lifecycle Holds

**Feature**: 020-agent-lifecycle | **Date**: 2026-09-19

How to run this feature's checks, and what each success criterion is proved by. Nothing
here is implementation — that is `tasks.md`.

---

## Prerequisites

```sh
cd /Users/alexcollins/Agents
xcodegen generate     # only after editing project.yml
```

The package tests need no runtime installed: `FakeLauncher` and `FakeACPAgent`
(`Packages/AgentsKit/Tests/AgentsKitTests/Fake/`) stand in for a real CLI, so the whole
daemon is exercised without a credential or a network.

---

## The three commands

```sh
# Everything. This is the gate.
swift test --package-path Packages/AgentsKit

# Just this feature's suites, while working on it
swift test --package-path Packages/AgentsKit --filter 'AgentState|AgentGroup|AgentStore|Recovery|WorkflowFiring|LegacyRecord'

# Both apps still build — the new state breaks 11 exhaustive switches by design
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

The app build is not optional. Adding a case to `AgentState` is what makes the compiler
enumerate every view that reads it, and a green package with a red app means the work is
half done.

---

## What proves what

| Criterion | Proved by | Where |
| --- | --- | --- |
| **SC-001** A new agent is only ever in the working group | A test that records every `agents/changed` from `startAgent` to first turn and asserts the group is `.running` throughout | `Integration/` — new suite |
| **SC-002** No record ever carries an ending that did not happen | The same recording, asserting `endedReason == nil` until an ending occurs | same suite |
| **SC-003** All 60 pairs decided | An exhaustive loop over `AgentState.allCases × AgentEvent` cases | `Unit/AgentStateTests.swift` |
| **SC-004** Every state change is recorded and counted | Transcript assertions on each ending path, including recovery | `Integration/DaemonTests.swift`, `Integration/` recovery suite |
| **SC-005** Stopped triggers fire on a restart | Kill the daemon under two agents; assert the workflow fires for the one that will not be picked back up and not for the one that will | `Integration/WorkflowFiringTests.swift` |
| **SC-006** No forbidden record reaches disk | Attempt to save each of the four broken shapes; assert each throws | `Unit/AgentStoreTests.swift` |
| **SC-007** A corrupted record opens, mended, and says so | Write each broken shape by hand, load, assert state and transcript line | `Unit/AgentStoreTests.swift`, `Unit/LegacyRecordTests.swift` |
| **SC-008** A newer build's state loses no agent | Write a record with `"state": "hibernating"`; assert it loads as `stopped`/`unrecognised` and round-trips the original | `Unit/LegacyRecordTests.swift` |
| **SC-009** One transition writer of `state` | A source scan over `Packages/AgentsKit/Sources`, with a reasoned allow-list for `AgentStore.mended` | `Unit/LifecycleWriterTests.swift` |

SC-009 is a source scan because it is the only honest way to check a claim about where code
may write. There is precedent: 018's plan uses source scans for the same reason, and
`TouchedPathsTests` already scans in this repo.

---

## Doing it by hand

Four things worth seeing with your own eyes, because a passing test about a flicker is not
the same as not seeing the flicker.

### 1. A new agent is never Stopped (US1)

1. Run the app. Pick a project.
2. Start an agent against the slowest runtime you have — one that takes a few seconds to
   hand back a session.
3. Watch the agent list the whole time.

**Expect**: it appears under **Working**, labelled "Starting", and becomes the ordinary
working row when its first turn begins. It is never under Stopped or Complete, not even for
a frame.

**Today**: it appears under **Stopped** first.

### 2. A start that fails still reaches you as an error (US1)

1. Sign out of a runtime, or rename its binary out of the way.
2. Start an agent with it.

**Expect**: the failure is reported exactly as it is today, and **no agent is made**. The
session is built before the record exists, so a runtime that will not start leaves nothing
behind to put into a stopped state.

**What is being checked by eye** is therefore that this feature changed *nothing* here —
the one way a new state could have broken it is if a half-made agent were left on the
list, and there is none.

### 3. A restart fires the workflows that were waiting (US2)

1. Add a workflow to a project with a `stopped` trigger.
2. Start two agents on long work. Let one of them be a chat that has already been picked
   back up once (start it, kill the daemon, let it come back, kill it again).
3. Kill the daemon outright:

```sh
kill "$(awk 'NR==1' "$(ls -d ~/Library/Application\ Support/Agents 2>/dev/null)/daemon.lock")"
```

   Take the pid from the target root's `daemon.lock` — never pattern-kill `agentsd`, which
   would take down the session you are working in.

4. Start the app again.

**Expect**: both agents get their "this agent was working when the daemon stopped" line.
The one that will not be picked back up fires the workflow. The one that is picked back up
does not, and carries on.

**Today**: neither fires.

### 4. A broken record is mended and says so (US3)

1. Stop the daemon.
2. Edit an agent's `agent.json` and delete its `endedReason` while leaving
   `"state": "stopped"`.
3. Start the app and open that agent.

**Expect**: it opens, under Stopped, and its transcript has a line saying what was mended.

**Today**: it opens exactly as written, and stays wrong forever.

---

## Where the store lives

```sh
ls ~/Library/Application\ Support/Agents/agents/
# <uuid>/agent.json        the record these invariants are about
# <uuid>/transcript.jsonl   where stateChanged and the mend notes go
```
