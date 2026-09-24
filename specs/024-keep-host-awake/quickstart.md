# Quickstart: proving the Mac stays awake

**Feature**: 024-keep-host-awake

Seven checks. Checks 1–4 are the feature and can be run at a desk in a few minutes. Check 5
needs a laptop on battery. Checks 6 and 7 are eyeball checks in the app.

The whole feature is observable from one command, which is the happy consequence of the
mechanism chosen in `research.md` §1 — the assertion carries our reason string into the
system's own list:

```sh
# The one thing to watch. Run it in a second terminal.
pmset -g assertions | grep -i agents
```

## Before you start

Three lanes share this working tree, so verify in a detached worktree rather than in place:

```sh
git worktree add --detach /tmp/wake HEAD
# copy your files in, then:
swift test --package-path /tmp/wake/Packages/AgentsKit
```

Build both schemes sequentially, with plug-in validation skipped — `xcodebuild` has nobody
to ask about SwiftTerm's build-tool plug-in and fails with three unexplained build commands
otherwise:

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Launch the app with a clean environment, or the daemon inherits this session's `CLAUDE_*`
variables and agents fail to authenticate once the session ends:

```sh
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    open ./build/DD/Build/Products/Debug/Agents.app
```

**Do not pattern-kill `agentsd`** — it is hosting these sessions. Take the pid from the
target root's `daemon.lock` if you need to stop a specific one.

---

## Check 1 — a turn in flight holds the Mac (FR-001, FR-002, US1)

Start an agent on something that runs for a minute or two.

```sh
pmset -g assertions | grep -i agents
```

**Expect** a line naming `agentsd` and `PreventUserIdleSystemSleep`, with a reason naming
how many agents are mid-turn:

```
pid NNNN(agentsd): [0x...] 00:00:14 PreventUserIdleSystemSleep named: "Agents: 1 agent is mid-turn"
```

**Expect not** `PreventUserIdleDisplaySleep` anywhere against `agentsd` (FR-007). The
screen is not ours to hold.

## Check 2 — it is let go the moment the turn ends (FR-004, US2-1)

Let that turn finish. Watch the same command.

**Expect** the `agentsd` line to be gone within five seconds of the agent landing under
**Done**. It should be immediate in practice: the release happens inside the same
`changed(_:)` that records the ending, not on a timer.

Repeat for the three other ways a turn ends, which are separate requirements and separately
easy to get wrong:

| Do this | Expect | Covers |
|---|---|---|
| Stop an agent by hand mid-turn | assertion gone at once | US2-3 |
| `kill` a runtime process mid-turn | assertion gone when the death is noticed | US2-4 |
| Let an agent ask you a question and leave it | **assertion gone while it waits** | FR-003, US2-2 |

That last row is the one to actually run, and the one most likely to be wrong. An agent
sitting on an unanswered question must **not** hold the Mac — it is the abuse the feature
exists to avoid, and `isHoldingAgents` (the neighbouring predicate) answers the opposite
way for the same agent.

## Check 3 — one assertion, however many agents (FR-006, US1-3)

Start three agents at once on long tasks. Let them finish at different times.

**Expect** exactly **one** `agentsd` line throughout, its reason naming three agents and
then fewer as they land, and the line disappearing only when the last one ends. Not three
lines. Not a line that vanishes when the first one finishes.

## Check 4 — it dies with the daemon, with nothing to clean up (FR-013, US2-6, SC-006)

With a turn in flight and the assertion visible, take the pid from `daemon.lock` for a
**scratch** copy of the app — not the one hosting this session — and:

```sh
kill -9 "$(cat /path/to/scratch/daemon.lock)"
pmset -g assertions | grep -i agents
```

**Expect** nothing. No line, no stale assertion, and nothing for you to clear up. This is
the kernel dropping a dead process's assertion, verified in `research.md` §2 — if you find
yourself writing cleanup code to make this pass, the design has gone wrong.

## Check 5 — the battery floor (FR-009, FR-010, FR-011, US3) — *needs a laptop*

The parts of this that a unit test cannot reach. `FakePowerSource` covers the truth table;
this covers the real IOKit reading.

1. On mains, with a turn in flight: **expect** the assertion held, whatever the charge
   (US3-1).
2. Unplug, with charge above 20% and a turn in flight: **expect** it still held (US3-2).
3. With charge **at or below 20%** on battery and a turn in flight: **expect** the
   assertion gone within 15 seconds — the workflow tick is what notices (FR-011, US3-3).
4. Plug back in, turn still running: **expect** it taken up again within 15 seconds,
   without waiting for the next turn (US3-4).
5. On a desktop Mac with no battery: **expect** it held, with no battery rule applying
   (US3-5, FR-012).

Steps 3 and 4 are the slow ones. If you do not want to discharge a laptop to 20%, raise
`Wake.batteryFloorPercent` temporarily in a scratch build — but the shipped figure is 20.

## Check 6 — the app says so, and says why (FR-015, FR-016, US4)

In the window, with a turn in flight, look at the sidebar footer.

| Situation | Expect |
|---|---|
| Nothing running | **nothing at all** about sleep |
| Agents mid-turn | "Keeping this Mac awake", naming how many are working |
| Mid-turn, battery below the floor | a *different* line saying the battery is why it is letting the Mac sleep |

The third is the one worth checking properly. "Nothing is running" and "running, but your
battery is low" must not read the same, or the person learns nothing from either.

Then: **open a second window while a turn is already in flight.** It must show the line
immediately, not wait for the next change. That is the fetch-on-connect half of the
contract, and it is the half that is easy to leave out.

## Check 7 — an old daemon does not break a new window

Run the new app against a daemon that predates this feature (or stub the method to answer
`method not found`).

**Expect** the window to open normally and simply say nothing about sleep. Not an error,
not an empty row, not a crash.

---

## What is out of scope, and must not be "fixed"

If you observe any of these, they are the design working as specified:

- **Closing the lid sleeps the Mac mid-turn.** A power assertion cannot survive it, and the
  entitlements that would change that are private to Apple (`research.md` §1, 005 §10).
- **Choosing Sleep from the Apple menu sleeps the Mac mid-turn.** An explicit instruction
  from the person beats a pending turn.
- **The screen goes dark and locks while agents work.** FR-007. That is the intent.
- **A sleeping Mac is not woken when a workflow wants to start an agent.** An assertion
  keeps an awake Mac awake; it cannot rouse a sleeping one.
- **A long-running build in a terminal does not hold the Mac.** A build is not a turn. Noted
  in `research.md` §6 as the obvious follow-up, deliberately not in this feature.

## Automated coverage

What the suite should cover without any of the above being run by hand:

| Level | What |
|---|---|
| Unit | `Wake.verdict` over the whole truth table in `data-model.md` §3, including both sides of the inclusive floor |
| Unit | `hasWorkInFlight` over all six agent states |
| Integration | a real start/turn/stop through `DaemonCore` with `RecordingWakefulness`: held once, released once |
| Integration | an agent taken to `waitingOnUser` never causes a hold |
| Integration | three overlapping agents cause exactly one hold and one release |
| Integration | `FakePowerSource` crossing the floor mid-turn releases; going back to mains re-takes |
| Integration | `wake/state` is broadcast on change and **not** on an unchanged `changed(_:)` |

Run them where the tree is quiet:

```sh
swift test --package-path /tmp/wake/Packages/AgentsKit --filter Wake
```

`DaemonTests.stoppingAnAgentBeforeItIsPickedUpWithdrawsIt` fails most runs on
`launchCount == 1`. It is pre-existing and is not this feature's.
