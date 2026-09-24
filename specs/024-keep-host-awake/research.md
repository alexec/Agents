# Research: The Mac Stays Awake While Its Agents Work

**Feature**: 024-keep-host-awake | **Date**: 2026-09-23

Everything below that says "verified" was run on this Mac, on macOS 27 (Darwin 27.0.0), in
a scratch binary at `/tmp/wake-spike` and `/tmp/notify-spike`. The two spikes are throwaway
and are not part of the feature.

## 1. The mechanism, and that it works from a helper with no GUI

**Decision**: `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled], reason:)`,
held by `agentsd`, released with `endActivity`.

`agentsd` is not an app. It is a plain Mach-O started by the app into a session of its own,
it links no AppKit, and it ends in `dispatchMain()`. The one thing that had to be checked
before anything else was whether a process shaped like that can hold a power assertion at
all — the whole feature is worthless if the assertion has to live in the window, because
the window is exactly what is not there when the person has walked away (FR-005).

**Verified.** A plain command-line binary calling `beginActivity` registers a real,
system-visible assertion:

```
pid 1140(wake-spike): [0x0008e76f00018f2e] 00:00:03 PreventUserIdleSystemSleep
    named: "wake-spike: pretending a turn is in flight"
```

Three things that matters for:

- It is `PreventUserIdleSystemSleep`, which is precisely FR-001 and precisely **not**
  `PreventUserIdleDisplaySleep`. The display is untouched, which is FR-007 for free rather
  than as a thing to be careful about.
- The `reason:` string is carried through verbatim into `pmset -g assertions`. That is the
  whole of SC-006's verification, and it means the person — or a support question — can see
  which process is holding the Mac awake and why, from a terminal, without the app.
- No entitlement, no privilege, no `NSApplication`. It is Foundation.

**Alternatives considered:**

- **`IOPMAssertionCreateWithName` directly.** What `beginActivity` is built on. Rejected:
  it is the same assertion with manual reference counting and a `CFRelease` to forget. The
  Foundation wrapper gives an opaque token that is hard to misuse, and this feature's whole
  risk is holding too long, not holding too little.
- **Spawning `caffeinate`.** Rejected firmly. It is a second process whose lifetime must be
  managed, it dies independently of the daemon, and a stray `caffeinate` outliving its
  reason is the exact failure FR-013 exists to prevent. `beginActivity` cannot be orphaned;
  `caffeinate` is nothing but orphanable.
- **`PreventSystemSleep`** (the stronger assertion, which survives more). Rejected: it is
  for things like a Mac acting as a server, it is a much bigger promise than a turn in
  flight justifies, and 005's §10 already calls a permanent assertion illegitimate.

## 2. It dies with the process, which is FR-013 for free

**Decision**: rely on the kernel's ownership of the assertion. Write no cleanup path.

FR-013 says a killed daemon must leave the Mac able to sleep, with nothing to clear up. The
tempting design is a file or a record saying "a hold was taken", plus a sweep at start-up to
undo a hold the last daemon left. That would be wrong, and the spike says so.

**Verified.** With the spike holding an assertion, `kill -9`:

```
=== before kill ===  1        (matches on "wake-spike")
=== after kill -9 ===  0
```

The assertion is owned by the process, not by the system, and the kernel drops it when the
process dies however it dies. So FR-013 requires **no code at all** — it requires that we do
not invent persistence. That is worth stating in the plan because the instinct to write a
recovery path here is strong and every line of it would be a liability.

This is also why the hold is not `agent.json`-backed and appears nowhere on disk: see
`data-model.md`.

## 3. Reading the power source from the same process

**Decision**: `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` from IOKit.ps,
in the daemon.

**Verified**, same spike, same non-GUI process:

```
providing power source type: Battery Power
  source: InternalBattery-0 state=Battery Power capacity=77/100 charging=false
```

That gives all three facts FR-009 to FR-012 need, with no AppKit and no entitlement:

| Requirement | Fact read |
|---|---|
| FR-009 on mains | `IOPSGetProvidingPowerSourceType` is `AC Power` |
| FR-010 floor | `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` as a percentage |
| FR-012 no battery | the power sources list is empty — a desktop Mac |

Note `kIOPSMaxCapacityKey` is *not* always 100; it is read and divided rather than assumed,
which is a one-line difference that matters on an aged battery.

**`ProcessInfo.isLowPowerModeEnabled` is deliberately not used.** Low Power Mode is a
request to use less energy, not a request to abandon work in progress, and the spec's edge
cases already say the hold still applies under it.

## 4. How the daemon notices a power change — and why not `notify(3)`

**Decision**: re-read the power source on the workflow ticker that already runs, every 15
seconds. No new timer, no C interop.

FR-011 wants the hold reconsidered when the power source changes without waiting for an
agent, and puts no latency figure on it. Two routes were examined.

**The notification route, examined and rejected.** IOKit publishes
`kIOPSNotifyPowerSource` (`com.apple.system.powersources.source`) and
`kIOPSNotifyTimeRemaining`. The obvious API, `IOPSNotificationCreateRunLoopSource`, is
**unusable here**: it needs a `RunLoop`, and `agentsd` ends in `dispatchMain()` and runs
none. The dispatch-based alternative, `notify_register_dispatch`, does work —

```
notify_register_dispatch(kIOPSNotifyPowerSource) status = 0 (0 == OK)
notify_register_dispatch(kIOPSNotifyTimeRemaining) status = 0 (0 == OK)
```

— but only after adding a bridging header for `<notify.h>`, because `notify_register_dispatch`
is not in Swift's Darwin overlay. In a SwiftPM package that means a C shim target added to
`Package.swift`, which is new build surface for this whole package.

And one thing was **not** verified: delivery. The spike posted the key to itself and no
callback ran, which is the expected result — those keys are posted by `powerd`, and an
unprivileged process posting them is ignored. So the route costs a new C target and its
central claim would have gone into the plan untested.

**Against that**, the daemon already runs `workflowTicker` every 15 seconds
(`DaemonCore.workflowTickInterval`, `DaemonCore+Workflows.swift:273`), and that ticker
already carries a second job of exactly this shape — it notices the local day rolling over
without a timer of its own. Reading three integers from IOKit on that tick is free, needs no
new machinery, and is trivially testable by injecting the reader.

Fifteen seconds of latency on "you just unplugged the laptop" is nothing: the floor is a
reserve, not a cliff, and the battery does not move a percent in fifteen seconds.

**Decision stands: poll on the existing tick.** If a future feature needs sub-second power
events for another reason, the `notify_register_dispatch` route is written up above and
works; it is not worth a C target for this.

## 5. Where the hold is decided, and the one funnel it hangs off

**Decision**: derive it in `DaemonCore.changed(_:)`, plus the workflow tick, plus once at
start-up. Never store the decision.

FR-014 says work out whether to hold from what the agents are doing *now*, rather than
restoring a remembered decision. So the question is which funnel every relevant change
passes through.

`DaemonCore.move(_:on:)` is the single transition writer that 020 built, and it is the
obvious candidate — but it is not sufficient on its own, and the code says why:

- An agent is created in `DaemonCore+Commands.swift:196` with `agents[agent.id] = agent`
  **directly**, before any transition. A new agent is `starting`, which FR-002 counts as
  work in flight, so a hook only on `move` would miss the first moments of every agent.
- `recover()` and the load path write `agents[...]` directly too
  (`DaemonCore.swift:435`).

`changed(_:)` is the wider funnel and the right one: every write that is worth telling a
window about goes through it (`DaemonCore.swift:300`), including the `changed(agent)` at the
end of `start`. `move` calls it. This is exactly how `projectChanged(forAgentIn:)` already
rides along, which is the precedent to copy.

So: **`changed(_:)` for agent-side causes, the workflow tick for power-side causes and as a
backstop, and one call at the end of `Daemon.start()`** so a daemon that restarts under a
resumed agent holds from its first moment. Three call sites into one idempotent
`reviseWakefulness()`, which computes and compares before acting.

Idempotence is the load-bearing property: `changed(_:)` runs on every token of streamed
output, so `reviseWakefulness()` must be cheap and must do nothing when nothing moved.
Comparing a derived struct against the last one and returning early is the whole of it.

**FR-004's five seconds is met by construction**, not by a timeout: the release happens
inside the same `changed(_:)` that records the turn ending, so it is immediate, and the
15-second tick is only a backstop against a cause nobody thought of.

## 6. `isHoldingAgents` is the near-miss, and must not be reused

**Decision**: a new, narrower derived predicate. Do not extend `isHoldingAgents`.

`DaemonCore+Lifetime.swift` already has a derived "is there work in hand" predicate, and it
is tempting to reuse. It is the wrong set, and deliberately so — it asks a different
question, *may the daemon exit*, and it answers yes to all of:

- `pendingPermissions` and `elicitations` — an agent blocked on a person, which **FR-003
  explicitly excludes**
- `agents.values.contains { $0.state.holdsRuntime }` — which includes `waitingOnUser`
- `shells.busyCount > 0` — a build running in a terminal
- `drafts`, `resuming`, `sending`

Reusing it would silently hold the Mac awake all night for an unanswered question, which is
the one abuse the spec names in US2 scenario 2. The two predicates are neighbours with
opposite treatments of the same state, and the plan keeps them apart with a comment at each
saying so.

One genuine question it raises, recorded and **left alone**: a shell with a long build in it
is work by any honest reading, and `isHoldingAgents` counts it. 024 does not, because its
answer was "turns in flight" and a shell is not a turn. Noted here as the obvious follow-up
rather than smuggled in.

## 7. The conflict with 005 §10, which is not a conflict

**Worth stating explicitly, because it reads as one.**

005's §10 designs an assertion held *while an agent is blocked on a human*, so the bridge
can poll the mailbox every second for the answer. 024 FR-003 forbids holding for exactly
that state. A reader with both specs open will think one contradicts the other.

They do not, and the distinction is the holder and the purpose:

| | 005 §10 | 024 |
|---|---|---|
| Who holds | the bridge (`agents-bridge`) | the daemon (`agentsd`) |
| Why | its own poll loop must keep running to receive an answer | a turn is computing |
| When | agent blocked on a person | agent `starting` or `running` |
| Built? | **No** — 005 T045 / 013 T032 are unbuilt | this feature |

Both can be true at once and mean different things: 005's is "this process has work to do",
024's is "an agent has work to do". Neither is affected by the other, and `pmset` would
simply show two named assertions.

The plan's obligation is only that 024's reason string be specific enough to tell them
apart at a glance, and that 024's code not be written in a way that assumes it is the only
assertion in the process. Both are cheap.

## 8. Telling the window — `cost/state` is the pattern

**Decision**: a new `wake/state` notification carrying a small `WakeState`, mirroring
`cost/state` exactly.

FR-015 and FR-016 need a derived daemon fact on screen, which is the same shape as the
spending figure, and that has a worked path through this codebase already:

| Layer | Cost | Wakefulness |
|---|---|---|
| Notification name | `cost/state` (`DaemonAPI.swift:120`) | `wake/state` |
| Payload | `DaemonAPI.CostState` | `DaemonAPI.WakeState` |
| Broadcast | `broadcastCostState()` | `broadcastWakeState()` |
| Fetched on connect | `DaemonAPI.Method.costState` | `DaemonAPI.Method.wakeState` |
| Held on the model | `AgentsModel.costState` | `AgentsModel.wakeState` |
| Read by the app | `AppModel.costState` | `AppModel.wakeState` |

The fetch-on-connect half matters and is easy to forget: a window opened *after* the hold
was taken has heard no broadcast, so it must ask. `AppModel.swift:332` shows the pattern,
including its tolerance of a daemon too old to know the method — which keeps a new window
working against an old daemon instead of failing.

**Where it shows.** The sidebar footer button at `ProjectListView.swift:195` already carries
a derived, whole-app fact with a secondary line under it ("£x left"). Wakefulness is the
same kind of fact and belongs in the same place, as a line that is present while held and
absent otherwise (FR-015's "stop saying so"). FR-016's battery case is the same line with
different words. No new pane, no new window.

## 9. The test seam

**Decision**: inject the power reading; drive the agents for real.

`DaemonCore.init` already takes `launcher`, `now`, `thresholds` and `mailbox` for exactly
this reason (`DaemonCore.swift:229`). A `PowerSource` protocol joins them, defaulting to the
IOKit one and replaced in tests by a fake that says mains, or battery at 9%, or no battery
at all. That makes FR-008 to FR-012 unit-testable with no hardware and no waiting.

The assertion itself gets the same treatment one level down: a `Wakefulness` protocol with
the `ProcessInfo` implementation and a recording fake, so a test can assert *taken once*,
*released once*, and — the one that matters — *not taken at all* for an agent waiting on the
person.

What is **not** faked is the agent lifecycle. The integration tests drive `DaemonCore`
through real starts, turns and stops with the existing fake launcher, as
`DaemonTests`/`AttentionTests` do, so the thing under test is the derivation, not a mock of
it.

Two facts from the existing suite to respect:

- `DaemonTests.stoppingAnAgentBeforeItIsPickedUpWithdrawsIt` is a known pre-existing
  flake and is **not** this feature's.
- Three lanes share this working tree, so verification goes in a detached worktree
  (`git worktree add --detach /tmp/<name> HEAD`) rather than in place.

## Summary of decisions

| # | Decision | Verified? |
|---|---|---|
| 1 | `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` in `agentsd` | Yes — spike, `pmset` |
| 2 | No persistence, no cleanup path; the kernel owns it | Yes — `kill -9` spike |
| 3 | `IOPSCopyPowerSourcesInfo` for mains / percentage / no-battery | Yes — spike |
| 4 | Poll power on the existing 15 s workflow tick, not `notify(3)` | Route tested; delivery not, hence rejected |
| 5 | Derive in `changed(_:)` + tick + start-up; idempotent | Read from source |
| 6 | New narrow predicate; `isHoldingAgents` untouched | Read from source |
| 7 | 005 §10 and 024 coexist — different holder, different purpose | Read from both specs |
| 8 | `wake/state`, modelled on `cost/state`; sidebar footer | Read from source |
| 9 | Inject `PowerSource` and `Wakefulness`; drive agents for real | Read from source |

No NEEDS CLARIFICATION items remain. The three scope questions were settled with Alex before
the spec was written and are recorded in its Assumptions.
