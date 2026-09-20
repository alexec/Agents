# Quickstart: validating Cost Limits

How to prove each user story actually works, in the order they ship. Every scenario is runnable, and
none of them spends real money: `DaemonCore`'s `SessionLauncher` is injectable and
`FakeACPAgent.Script.usage` already carries a `cost` block, so the whole feature can be driven end
to end against a temporary root with no CLI, credential or network.

`Integration/TurnUsageTests.swift` is the existing precedent and the place to start reading — it
already asserts that a turn's cost is banked once and added up.

## Prerequisites

```sh
xcodegen generate      # after editing project.yml
swift test --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Tests are Swift Testing (`import Testing`), under `Packages/AgentsKit/Tests/AgentsKitTests`, split
`Unit` / `Integration` / `Live` / `Fake`. Pure rules — is this agent at its limit, which local day
is this, what is left — go in `Unit` and need no daemon. Anything that drives `DaemonCore` goes in
`Integration`.

Run a second app against a throwaway root so nothing touches your real agents **or your real
limits**. One root is one set of limits and one day, so the test budget and yours never meet:

```sh
open Agents.app --args --root /tmp/agents-cost-test
```

To watch what the daemon is actually counting:

```sh
cat /tmp/agents-cost-test/limits.json
cat /tmp/agents-cost-test/spend.json
```

**The one thing to get right before anything else.** Script the fake runtime to report a cost, or
every scenario below passes vacuously by never reaching a limit:

```swift
script.usage = ["inputTokens": 6, "outputTokens": 256, "totalTokens": 900,
                "cost": ["amount": 0.50, "currency": "USD"]]
```

---

## Story 1 — An agent that runs away stops itself

### By hand, in the app

1. Open **Settings → Cost** (⌘,). It exists; before this feature the app had no Settings window at
   all. Set **Per agent** to a figure you can reach in two or three turns of real work.
2. Start an agent and give it work. Watch the figure beside the context ring: it now reads
   `$0.42 of $2.00` rather than `$0.42` alone (FR-023).
3. Keep prompting. As it nears the limit the headroom takes on the app's existing "needs a person"
   colour — the same `Usage.closeToFull` threshold the context ring uses, not a second number
   (FR-025).
4. When it crosses: the turn it was in **finishes**. Then the agent stops. Its row reads *Reached its
   cost limit*, not *Stopped by you* and not *Complete* (FR-008, FR-010).
5. Open the conversation. The last turn is whole — not cut off mid-sentence, no tool call without its
   result. A sentence in the app's own voice says the limit stopped it and what it had spent.
6. Send it another prompt. You are told it is at its limit and offered the two things that change
   that: raise the limit, or let this one go on (FR-015, US1 scenario 3).
7. Choose **let this one go on**. That agent alone can work again; check Settings and confirm the
   app-wide limit is untouched (FR-016).
8. Clear the per-agent limit. Everything behaves exactly as it did before this feature — no headroom
   shown, nothing stopped (FR-003, SC-010).

### In tests

| Assert | Where |
|---|---|
| The turn that crosses the limit completes and is recorded in full before the agent stops | `Integration/TurnUsageTests.swift` |
| The ending is `.costLimit`, and `EndedReason.costLimit.isFinish` is false | `Unit/CostLimitTests.swift` |
| `isAtCostLimit(under:)` is false when no ceiling is set, false when unmeasured, true at exactly the limit | `Unit/CostLimitTests.swift` |
| Lowering the limit below an existing total makes that agent at-limit with no sweep and no write | `Unit/CostLimitTests.swift` |
| `costCeiling` survives a round trip, and an unknown extra key in the record is not lost | `Unit/AgentStoreTests.swift` |
| A ceiling set on one agent changes no other agent and neither app-wide limit | `Integration/CostLimitTests.swift` |

---

## Story 2 — A day cannot cost more than you said

### By hand, in the app

1. In **Settings → Cost**, set **Per day** low enough to reach in one sitting. Leave the per-agent
   limit off, so you are testing only this.
2. Run agents until the day's figure in the sidebar meets it.
3. Try to start a new agent: refused, naming the day's limit (FR-009).
4. Prompt an agent that already exists. Your words are **not** thrown away — they sit on its queue,
   and the conversation says why nothing is happening. This is the behaviour a runtime that will not
   start already has, and losing what you typed because a budget was reached would be the worst
   reading of "control cost".
5. Anything that was mid-turn when the limit was reached finishes that turn and then holds. Nothing
   is cut off.
6. Confirm a workflow refuses too: open a project with one and tap **Run now**. Its row says the
   day's limit, in grey rather than colour — midnight fixes this without anybody (FR-014).
7. Quit the app entirely and reopen it. The day's figure is what it was, not zero (FR-021, US2
   scenario 6).
8. Raise the day's limit. Whatever was holding goes immediately, with no restart (FR-017).

### The rollover, without waiting until midnight

Waiting for a real midnight is not a test. Three ways, cheapest first:

1. **Unit** — `SpendLedger` takes the date as a parameter. Bank on one day stamp, read on the next,
   assert zero. No daemon.
2. **Integration** — bank at a supplied `Date`, then ask `DaemonCore` for a day that is not that one.
   `tickWorkflows(now:)` already accepts an injected `now` for exactly this reason; the rollover
   drain rides on the same tick and takes the same parameter.
3. **By hand** — edit `spend.json`, change today's key to yesterday's date, and watch the sidebar and
   anything holding within one tick.

Assert on all three of: the day's figure returns to zero, refused work starts flowing again with no
action from the reader, and an agent that was holding can be prompted **where it stands**, with its
conversation intact, rather than having to be started afresh (FR-012).

### In tests

| Assert | Where |
|---|---|
| Day stamps, rollover, pruning at seven days, and two currencies kept apart | `Unit/SpendLedgerTests.swift` |
| `agents/start` is refused with `dayLimitReached`; `agents/prompt` is **not** refused and the words stay queued | `Integration/CostLimitTests.swift` |
| A turn in flight when the limit is reached completes, then nothing drains | `Integration/CostLimitTests.swift` |
| A fire refused by the day's limit is recorded as `dayLimitReached`, with `needsAPerson` false, and twenty of them collapse to one row with a count | `Integration/WorkflowRefusalTests.swift` |
| The ledger is written before `cost/changed` is broadcast | `Integration/CostLimitTests.swift` |
| A daemon restarted mid-day resumes the day's true total | `Integration/CostLimitTests.swift` |

---

## Story 3 — You can see what you are spending and how much is left

### By hand, in the app

1. With both limits set, run an agent part-way to each. Without opening anything, read off: what this
   agent has spent and what is left of its limit (beside the context ring), and what today has cost
   and what is left of the day's (the sidebar).
2. The sidebar figure is now **today**, not this sitting. Close the window and reopen it: the number
   does not reset, which is the whole reason for the change.
3. Set both limits to nothing. Both headroom figures disappear and you are back to the figures the
   app showed before (FR-026).
4. Open the same agent on the phone. *Reached its cost limit*, in the same words — they come from one
   switch in Core, which is why (FR-027).

### The unmeasured case — do this one, it is the easy one to skip

1. Script a fake runtime, or use a real runtime that reports no cost, and run an agent on it with
   both limits set.
2. Where its cost would be, it says it cannot be measured. It is **never** shown as being within a
   limit, at any headroom, on any surface (FR-013, SC-008).
3. It runs past the per-agent limit without stopping, because there is nothing to compare, and it
   contributes nothing to the day's total.

This is the failure this feature most needs to not have: a reader who sets a limit, sees no warning,
and believes they are covered when nothing is capped.

---

## What must still be true afterwards

| Check | Why |
|---|---|
| With both limits cleared, nothing is stopped, nothing refused, nothing new shown | SC-010. The feature must be invisible when off. |
| No sequence of agent or workflow actions raises or removes a limit | SC-009 and FR-007. Grep the MCP surface and `AppService` for the new methods and find nothing. |
| No turn is ever cut short by a limit | The spec's one rule. A transcript ending mid-tool-call is a bug in this feature. |
| `agents/stop`, `agents/archive` and `agents/unqueue` work while a limit is reached | The reader must always be able to stop and tidy up, budget or no budget. |
| Overnight, unattended, with workflows running, the day's spend lands at or under the limit | SC-004 — the reason the gate is in the daemon and not in the app. |
