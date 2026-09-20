# Research: Cost Limits

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Date**: 2026-09-19

Eleven decisions. Nine were settled by reading the code that already exists; two are genuine
trade-offs where the alternative is defensible and was rejected for a stated reason.

---

## 1. Where a limit refuses work

**Decision.** One guard in `DaemonCore.sendNextQueued(to:)`, plus one in `DaemonCore.start(_:)`.

**Rationale.** `sendNextQueued` is the single funnel into `beginTurn`. Everything that starts a turn
passes through it:

| Caller | Route |
|---|---|
| A person typing | `prompt(_:)` appends to the queue, then calls it |
| The next queued prompt | `drainQueue(after:)` calls it when a turn ends of its own accord |
| A workflow firing | `adoptAndPrompt` → `prompt(_:)` → it |
| A restarted chat being picked back up | 011's `pickUp(_:)` → `prompt(_:)` → it |

Four callers, one gate. It also already behaves the way a held prompt should: its own comment says
"the runtime is started before the prompt leaves the queue, so a runtime that will not start leaves
the words exactly where they were." A limit is the same situation — a turn that cannot begin now and
may be able to later — so holding is not a mechanism this feature invents, it is the mechanism that
is already there.

`start(_:)` needs its own guard because a new agent has no queue to wait on. It is placed *before*
the session is made: refusing after spawning a runtime process would cost time and a process for a
turn that was never going to run.

**Alternatives considered.** Gating in `prompt(_:)` — rejected, because it would have to refuse the
call and throw the person's words away, when leaving them queued is both kinder and already
implemented, and because it misses `drainQueue`. Gating in the app before it calls the daemon —
rejected outright: the daemon is the only thing always running, and a limit that does not bind a
workflow firing at 3am with no window open is not a limit.

---

## 2. When a limit is noticed

**Decision.** In `finishTurn(agentID:result:)`, immediately after the runtime's cost is banked into
`costToDate`, and not before.

**Rationale.** The spec's answer — the turn is the unit, a limit never cuts a turn short — makes
this the only honest moment. Banking is what makes the limit true, so the check belongs on the next
line after it. Nothing needs to watch a running turn, cancel a `turnTask`, or decide what to do with
a half-applied edit.

There is a second, quieter reason. `Usage` arrives mid-turn down the session's event stream and
carries a cost too, so a mid-turn check is *possible*. It was rejected because acting on it means
interrupting, and because `TurnUsageTests` documents that the mid-turn meter and the turn's own
total "come from two different places … so neither one arriving says anything about the other". The
turn's own total, off the prompt's reply, is the figure to bank and the figure to judge.

**Consequence, stated plainly.** Both limits overshoot, by at most one turn per agent that was
already working. `finishTurn` cannot refuse a turn that has already happened. This is the price the
spec accepted and SC-001 and SC-002 are written to measure it rather than to pretend otherwise.

---

## 3. Remembering what today cost

**Decision.** A new `spend.json` at the daemon root: local day stamp → currency → amount, holding
the last seven days and pruned on write.

**Rationale.** FR-021 asks for a day's total that survives a restart and attributes a late figure to
the day it belongs to. A single `{today, totals}` pair cannot do the second: a turn that ends at
23:59:59 and a daemon that reads the file at 00:00:01 would have to guess. Keying by day removes the
guess entirely, and seven days of a few currencies is a few hundred bytes.

Seven is not a history feature and must not be presented as one — the spec puts spending history out
of scope. It is chosen because it costs nothing and makes every boundary question unambiguous,
including a machine that slept through two days.

The file sits beside `projects.json`, `workflows.json` and `option-cache.json`, which is the pattern
`StoreLocations` already establishes for "one small fact the daemon owns". It is written inside
`finishTurn` before `changed(agent)`, following the codebase's rule that the record is written
before the windows are told: a daemon killed mid-bank comes back having counted the money.

**Alternatives considered.** Deriving the day's total from the transcripts, which already contain
timestamped `.usageRecorded` entries — genuinely tempting, since it needs no new file and cannot
drift from the truth. Rejected because it makes daemon startup O(every transcript ever written) for
a number needed on every prompt, and because transcripts are paged. Keeping the total only in memory
— rejected: it would reset on every daemon restart, and FR-021 and US2 scenario 6 exist precisely to
forbid that.

---

## 4. Which day it is

**Decision.** The machine's local calendar day, from `Calendar.current` and the current
`TimeZone`, stamped as `yyyy-MM-dd`. The day a spend belongs to is the day its turn ended.

**Rationale.** FR-019 asks for the machine's own local day, following the time zone when it changes.
Taking the stamp at the moment of banking means no spend is ever unattributed and no clock
arithmetic is needed. A day shortened or lengthened by a clock change is still one day, and a
traveller who crosses a boundary gets a short day and then normal ones — which is what the spec's
edge case asks for and what anyone would expect from the phrase "today".

This is also what makes US2 scenario 5 fall out for free: an agent running across the rollover ends
its next turn on the new day, so that spend lands on the new day without anybody reasoning about it.

**Alternatives considered.** UTC days — rejected, because "today" on a machine in California is not
a UTC day and a limit that resets at 4pm would be a bug report. A rolling 24-hour window — rejected:
it is arguably fairer, but it cannot be explained in a sentence, and "how much have I got left
today" stops having an answer you can check against a calendar.

---

## 5. "At its limit" is computed, never stored

**Decision.** `Agent.isAtCostLimit(under:)` and `Agent.costHeadroom(under:)` are pure functions on
`Agent` in Core, taking the limits as a parameter. No `AgentState` case, no stored flag, no change
to `applying(_:endedReason:)`.

**Rationale.** The codebase is explicit about this and says so out loud: `filesToShow` "is not a
state and must never become one", and `Usage.isCloseToFull` is "one number, in the kit, with a test.
Not a view's idea of *nearly*". Three concrete benefits here:

1. Lowering the limit is instantly correct for every existing agent. A stored flag would need a
   sweep over every record, and would be wrong between the change and the sweep.
2. The rule is exhaustible in a unit test with no daemon, no store and no fake runtime.
3. Both platforms ask the same function, so the window and the phone cannot disagree.

**The one place this is not enough.** FR-010 asks that an agent stopped by a limit *record* an
ending that says so, and an ending is by nature a stored fact about a moment. So both exist and they
answer different questions: `EndedReason.costLimit` says *this is the turn where it happened*, and
the computed rule says *this is why you cannot prompt it now*. The refusal path reads the computed
rule, never the stored ending.

**The tension worth naming.** A turn can end with `endTurn` — the agent genuinely finished — *and*
cross the limit. Recording `costLimit` slightly overstates the case. It is recorded anyway, because
the ending is the app's answer to "why can I not talk to this?", and from that moment the limit is
the answer. The transcript carries the fuller truth in a sentence.

---

## 6. An agent whose runtime reports no cost

**Decision.** `Agent.costIsUnmeasured` is true once a turn has ended reporting no cost at all. Such
an agent is never stopped by a limit, contributes nothing to the day, and is labelled wherever its
cost would otherwise be.

**Rationale.** `Cost?` is optional on both `Usage` and `TurnUsage`, and `Cost.init?(wire:)` returns
nil for a runtime that sends no currency — so this is not hypothetical, it is the existing shape of
the data. The failure mode it guards against is the worst one available to this feature: a reader
who sets a limit, sees no warning, and believes they are covered when nothing is capped. FR-013 and
SC-008 exist for it.

It follows, and the spec says so, that **the day's total is a floor rather than a fact** whenever
such an agent is running. The app must not round that away.

**Alternatives considered.** Estimating cost from tokens for runtimes that report none — rejected;
it is exactly the estimate the app refuses to make everywhere else, and a limit enforced on a guess
is worse than no limit because it looks like one. Refusing to run unmeasurable runtimes at all while
a limit is set — rejected as wildly out of proportion.

---

## 7. The sidebar figure becomes today's

**Decision.** `AppModel.sessionCost` and `spentBeforeWeWatched` retire. `ProjectListView` shows
today's total and its headroom, from the daemon.

**Rationale.** This is the one place the feature changes behaviour that already works, so it is
argued rather than assumed. "This sitting" was the best available answer to "what am I spending"
when nothing durable existed — its own comment explains the baseline arithmetic needed to stop it
being "an all-time figure wearing the word session". Today's total is the better fact by every
measure: it is what the limit is actually measured against, it survives closing the window, it does
not silently reset when the app is reopened, and it needs no baseline subtraction. Keeping both
would put two similar money figures in one sidebar, which is how a reader learns to trust neither.

FR-024 also requires the day to be visible "without the reader opening a page kept for the purpose",
and this is the surface that already carries a total.

**Alternatives considered.** Keeping the sitting figure and adding today's beside it — rejected for
the two-figures reason above. Showing today only in Settings — rejected against FR-024.

---

## 8. Two currencies

**Decision.** A limit is an amount and a currency. Only spend in that currency counts against it.
Spend in another currency is shown, is added to the day's ledger under its own key, and is not
capped.

**Rationale.** `Cost.adding(_:)` already returns nil across currencies and `Cost.total(of:)` already
joins rather than sums, with the reason recorded in the source: adding two of them "would be a
number nobody could check". A limit cannot be more permissive about arithmetic than the display is.

In practice every runtime in the catalogue reports USD, so this is a correctness rule that almost
never shows. It is still a real hole and the spec names it rather than hiding it: an uncapped
currency must be visible, not silently ignored.

**Alternatives considered.** Converting at a fetched rate — rejected; it needs a network service, it
makes the cap depend on a third party, and it breaks the rule that every figure the app shows is the
runtime's own. One limit per currency — rejected as a configuration surface nobody with one currency
should have to see.

---

## 9. Where a limit is set

**Decision.** A `Settings` scene in `AgentsApp.swift` — the app's first — with one Cost pane.

**Rationale.** The app has no preferences of any kind today: `AgentsApp` is a bare `WindowGroup`
with one command. The limits are per-reader, per-machine, and long-lived, which is what a Settings
window is for, and macOS gives ⌘, and the menu item for nothing. The alternative homes are all
worse: the sidebar is for what is happening now, the project page is per-project and these limits
are not, and a sheet raised only when a limit is hit cannot be found before that.

The pane shows the two limits and what they have stopped, so the answer to "why did that not run"
is in the same place as the number that caused it.

**Scope note.** Building the first Settings window means choosing where preferences live and what
the pane looks like. What *else* eventually belongs in Settings is deliberately not decided here.

---

## 10. Keeping limits out of agents' reach

**Decision.** No limit method is advertised to `AppService`, added to the MCP tool surface, or
mentioned in any standing instruction. `cost/setLimits` and `agents/setCeiling` are window calls
only.

**Rationale.** This is 008's reasoning applied to money, and it is the same sentence: a runaway that
can raise its own limit is not stopped. 008 went further and refused to make the chain-depth limit
configurable at all for this reason, and it explicitly declined to tell agents about
`manage_workflows` because "telling every agent it can schedule things would invite exactly the
behaviour the chain-depth limit exists to contain."

FR-007 and SC-009 make it testable rather than merely intended.

---

## 11. The colour of a workflow refused by the day's limit

**Decision.** `WorkflowRefusal.dayLimitReached`, with `needsAPerson: false`.

**Rationale.** The existing rule, written down in `WorkflowOutcome.swift` and in 008's wireframe, is
that colour is spent only on refusals that will keep happening until somebody acts, because colour
in this app means a person is needed. A workflow refused by the day's limit resolves itself at
midnight with no action at all — the same shape as `missedWhileClosed`, which is also grey.

It is also not the place to raise the alarm. The day's limit being reached is one global fact shown
in the sidebar and in Settings; a project page shouting about it once per workflow would say the
same thing many times in the wrong place.

**Alternative considered.** Colouring it, on the grounds that the reader may well want to raise the
limit rather than wait for midnight. Rejected: wanting to act is not the same as needing to, and the
reader has already been told, in the one place that owns the fact.
