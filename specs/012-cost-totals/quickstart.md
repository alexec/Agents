# Quickstart: validating Cost Totals

How to prove each user story works, in the order they ship. No scenario spends real money:
`DaemonCore`'s session launcher is injectable and `FakeACPAgent.Script.usage` already carries
a `cost` block, so the whole feature is drivable end to end against a temporary root with no
CLI, credential or network.

Two existing tests are the places to start reading.
`Integration/TurnUsageTests.swift` already asserts that a turn's cost is banked once and added
up — that is the input to everything here. `Integration/ProjectsTests.swift` already exercises
`allProjects()`, which is where the project total is computed.

## Prerequisites

```sh
xcodegen generate      # after editing project.yml (a new App/Sources/Spending/ folder)
swift test --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Tests are Swift Testing (`import Testing`) under `Packages/AgentsKit/Tests/AgentsKitTests`,
split `Unit` / `Integration` / `Live` / `Fake`. Everything about the *grand total* is pure and
belongs in `Unit/SpendingTests.swift` with no daemon at all — hand-build `ProjectSummary`
values and fold them. Only "a spent cost reaches the summary and is broadcast" needs
`Integration`.

Run a second app against a throwaway root so nothing touches your real agents:

```sh
open -n Agents.app --args --root /tmp/agents-cost-totals
```

**The one thing to get right before anything else.** Script the fake runtime to report a cost,
or every scenario below passes vacuously by totalling nothing:

```swift
script.usage = ["inputTokens": 6, "outputTokens": 256, "totalTokens": 900,
                "cost": ["amount": 0.50, "currency": "USD"]]
```

And for the unmeasured path, the same block **without** `cost` — usage but no price, which is
the case `Agent.isUnmeasured` exists to name:

```swift
script.usage = ["inputTokens": 6, "outputTokens": 256, "totalTokens": 900]
```

---

## Story 1 — What has this project cost? (P1)

Shippable alone. Needs only the two `ProjectSummary` fields and the caption in the heading;
the Spending window need not exist.

**In tests** (`Integration/ProjectsTests.swift`, extended)

1. Start two agents in one temporary folder, run a priced turn in each, and assert the
   folder's `ProjectSummary.costToDate["USD"]` is the sum of both agents' `costToDate`.
2. Archive one of them and assert the summary's total is **unchanged**. This is SC-005 and it
   is the assertion most likely to catch a future regression, because archiving is the one
   operation that visibly removes an agent from a page.
3. End an agent and assert the same.
4. Run a turn priced in `GBP` beside one priced in `USD` and assert two keys with the right
   amounts and no third key — nothing was converted or combined. (SC-006)
5. Run a turn with usage but no `cost`; assert `unmeasuredAgents == 1` and that `costToDate`
   did not gain a zero entry.
6. A folder where an agent was started but no turn has finished: `costToDate` empty,
   `unmeasuredAgents == 0`. Started is not unmeasured.
7. Capture the `project/changed` notification from the priced turn and assert the total is on
   it — this is FR-005, and it is the reason the design needs no notification of its own.

**By hand**

Open the project. Under its name, one line: what it has cost. Send a prompt and watch the
figure move without leaving the page. Archive a chat in it and watch the figure *not* move.
Open a project you have never run anything in — no line at all, not a zero. (FR-004)

---

## Story 2 — What has all of it cost? (P2)

**In tests** (`Unit/SpendingTests.swift`, new — no daemon)

1. **The invariant, first.** Build a handful of `ProjectSummary` values with mixed currencies,
   some archived, some with `exists: false`, some with nothing spent. Assert that for every
   currency, the `shares` sum exactly to `grandTotal`. This is FR-011, it holds by
   construction today, and it is the thing a later feature would break silently. ([research.md
   §3](./research.md))
2. Ordering: shares come back largest first, within a currency.
3. Two currencies: `currencies` has both, each section is ordered independently, and no figure
   from one appears in the other.
4. A project with empty `costToDate` is not in any share list and contributes nothing.
5. Archived projects and missing folders **are** in the share lists, and carry `isArchived` so
   the page can say so. (FR-013, FR-014)
6. `unmeasuredAgents` is the sum across projects.
7. Nothing spent anywhere: `isEmpty` is true, `grandTotal` empty, `currencies` empty.

**By hand**

Spend in two or three projects. Open Spending — from the money line at the foot of the
projects column, and again from the menu item. Check three things:

- The grand total is the first thing on the page.
- Every project that has spent is listed, biggest first.
- **Each listed figure is the same one that project's own page shows.** (SC-004 — the
  cross-check that proves the two surfaces are reading the same number.)

Then add them up on paper. They must come to the grand total exactly. (SC-003)

Leave Spending open, send a prompt in the main window, and watch both the grand total and that
project's line move. (FR-016)

Close Spending. The main window is on exactly the project and chat you left it on — which is
free, because it was never navigated away from. (FR-018)

---

## Story 3 — The total is the whole bill, and says so when it is not (P3)

This story is mostly assertions on the work already done rather than new code, which is why
it is last and why it is short. The one piece of new UI is the unmeasured line.

**By hand — the sequence that proves it**

Do these in order, watching the grand total after each step. It must never fall.

1. Spend in a project. Note the grand total.
2. Archive a chat in it. Total unchanged.
3. Archive the whole project. Total unchanged; the project is still listed on the Spending
   page, marked archived. (FR-013)
4. Start an agent in a folder you never added as a project, and let it spend. A new project
   appears — derived, named after the folder — and the total rises by what it spent. Nothing
   is missing and nothing is filed under "other", because there is no "other".
   ([research.md §3](./research.md))
5. Delete the project's folder from disk. It is still listed, still carrying its spend, and
   the sidebar still says the folder is missing. (FR-014)
6. Run an agent on a runtime that reports no cost. The page says how many agents could not be
   measured; the grand total reads as a floor. (FR-015, SC-008)

**Restart** (SC-007, FR-020)

```sh
pkill -f 'agentsd.*agents-cost-totals'
```

Reopen the app against the same root. Every total is exactly what it was. Nothing was written
to disk by this feature — the totals come back because the agent records do.

**The one that is a deliberate limitation**, worth doing once so it is known rather than
discovered: delete an agent's directory under `<root>/agents/<uuid>/` and reopen. Its spend is
gone from both totals. That is the honest behaviour of a ledger of records held, and the spec
says so.

---

## The whole feature, in one pass

With all three stories in:

```sh
swift test --package-path Packages/AgentsKit --filter Spending
swift test --package-path Packages/AgentsKit --filter Projects
swift test --package-path Packages/AgentsKit --filter TurnUsage
```

Then, by hand: two projects with spend in them, one archived chat, one archived project, one
unpriced agent. Open Spending, add the shares up on paper, and confirm they equal the grand
total and that each equals its own project page. If that holds, every functional requirement
except the multi-currency ones has been exercised; for those, script a `GBP` turn beside a
`USD` one and confirm you are looking at two sections and never at one number.
