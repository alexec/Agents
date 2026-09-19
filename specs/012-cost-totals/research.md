# Phase 0 Research: Cost Totals

Every question this feature raised was answerable from the codebase rather than from the
outside world. There were no NEEDS CLARIFICATION markers in the Technical Context to resolve;
what follows are the eleven decisions that shaped the design, each with what was rejected.

---

## 1. Where the project total is computed

**Decision**: In `DaemonCore.allProjects(includeArchived:)`, accumulated in the pass that
already builds `counts`, and carried on `DaemonAPI.ProjectSummary` as `costToDate`.

**Rationale**: That function opens with
`Dictionary(grouping: agents.values) { Project.standardize($0.cwd) }` and then walks each
folder's agents to count them by group. Summing `costToDate` per currency is three lines
inside a loop that is already running, over a collection that is already grouped, using the
standardization rule that already decides which folder an agent belongs to. It is also the
only place in the app where that grouping is allowed to happen, which keeps the window from
ever forming its own opinion about which project an agent is in.

**Alternatives considered**:

- *Compute it in the window from `AgentsModel.agents`.* The client does hold every agent, so
  this would work. Rejected because it would put a second implementation of "which project is
  this agent in" in the app, one that would have to re-apply `Project.standardize` and would
  drift the first time the daemon's rule changed. It would also give the phone nothing.
- *A new `cost/project` daemon method.* A round trip to compute a sum the caller could not
  have computed anyway, and a second source of truth for a figure `ProjectSummary` is already
  the vehicle for.

---

## 2. How the totals stay live

**Decision**: Nothing is added. `DaemonCore.changed(_:)` already ends with
`projectChanged(forAgentIn: agent.cwd)`, and `finishTurn` calls `changed(agent)` on the line
directly after banking the cost into `costToDate`.

**Rationale**: This is the whole reason to put the total on `ProjectSummary` rather than
anywhere else. The notification that carries a project's changed *counts* to every window is
already sent at exactly the moment a cost is banked, because banking the cost is an agent
change. FR-005 and FR-016 are therefore satisfied by code that was written for a different
reason and is already tested. The grand total follows because the page is a function of
`AgentsModel.projects`, which `upsert(_:)` maintains from that same notification.

**Alternatives considered**:

- *A `cost/changed` notification.* A second broadcast on the same event, arriving at a
  slightly different time, which two windows could observe in two orders. 010 needs such a
  notification because a daily total is not a property of any project; this feature does not.
- *Polling on a timer.* The app has a 15-second workflow heartbeat and nothing else polls.
  Adding a poll for a number that is already pushed would be strictly worse in both latency
  and work.

---

## 3. Unassigned spend does not exist, and FR-011 holds by construction

**Decision**: Implement no "spend belonging to no project" category. Prove FR-011 — that the
shares add up to the grand total exactly — with a test, and note in the data model that
FR-012 is vacuous.

**Rationale**: `DaemonCore+Projects.swift` says it plainly in its own doc comment: "The list
is the union of every folder an agent has run in and every record we kept." An agent started
in a folder nobody added does not fall outside the projects — it *creates* one, derived, dated
from its oldest agent. An agent in a subfolder of a project creates a separate project for the
subfolder, which is the existing behaviour and is the honest one: the app does not guess a
parent. So there is no folder an agent can be in that is not a project, and every penny is
therefore inside exactly one project's total.

This is the happiest kind of finding — a requirement written to guard against an omission that
the architecture had already made impossible. But it is worth a test rather than a shrug,
because it is an invariant a future feature could break without noticing: anything that starts
filtering `allProjects()` before totalling would silently lose money from the grand total. The
test sums the listed shares and asserts equality with the grand total, per currency, including
archived projects and projects whose folders are gone.

**Alternatives considered**:

- *Build the "Other" row anyway, defensively.* A row that can never appear is a row nobody
  will maintain and nobody will notice has rotted. The invariant test is the same guarantee
  with none of the dead code.
- *Attribute a subfolder agent to its enclosing project.* Rejected: it contradicts the
  existing grouping rule, would make a project's total disagree with the agents listed on its
  own page, and requires the app to guess at a hierarchy the reader never declared.

---

## 4. What "unmeasured" means, operationally

**Decision**: `Agent.isUnmeasured` is `lastTurnUsage != nil && costToDate.isEmpty` — a pure
computed property in Core. `ProjectSummary.unmeasuredAgents` counts them per project; the
Spending window sums that count.

**Rationale**: The spec needs to distinguish three things that all look like "no money":
an agent that has not run yet, an agent that ran and cost nothing, and an agent whose runtime
would not say. `finishTurn` sets `lastTurnUsage = usage` whenever the runtime reports usage at
all, and only adds to `costToDate` when `usage.cost` is non-nil. So a completed turn with no
price on record is exactly the case the spec calls unmeasured, and an agent that has never
finished a turn is correctly excluded. No new field, no new state, and it is retroactively
correct for every record already on disk.

**Alternatives considered**:

- *Ask the runtime whether it reports cost.* There is no such capability in the protocol, and
  the app's rule is that cost is whatever the runtime volunteers. A declared capability could
  also be wrong, and the evidence on the record cannot.
- *Treat an empty `costToDate` as unmeasured.* Would mark every freshly started agent as
  unmeasured and put a warning on a project where nothing has happened yet.
- *Store a flag when a turn ends without a price.* A stored fact that is already derivable,
  and one that would need a migration for existing records.

---

## 5. The grand total is a pure function in Core

**Decision**: A `Spending` type in `AgentsKitCore/Model/Spending.swift`, built from
`[DaemonAPI.ProjectSummary]`. No daemon method.

**Rationale**: The window holds every project already — `AgentsModel.projects` is seeded by
`projects/list` on connect and kept current by `project/changed` — so the grand total is a
fold the client can do itself, and a fold with no I/O is a fold a unit test can exhaust in
milliseconds with hand-built summaries. Putting it in Core rather than in `AppModel` means the
ordering rule, the per-currency rule and the unmeasured count are written once and the phone
inherits them.

**Alternatives considered**:

- *A `cost/total` daemon method.* Would move the arithmetic to the one process that must never
  be slow, add a method to the surface, and give a figure that could disagree with the shares
  listed beside it if the two were computed at different moments. The current design cannot
  produce that disagreement, because both come from the same array in the same render.
- *A computed property on `AppModel`.* Mac-only, and untestable without a `@MainActor` model.

---

## 6. The Spending page is its own window

**Decision**: A second `Window("Spending", id: "spending")` scene in `AgentsApp`, sharing the
single `AppModel` created as `@State` on the `App`. Opened from the money line at the foot of
the projects column and from a menu item.

**Rationale**: Confirmed with the reader before the design was fixed. Three things recommend
it. FR-018 — leaving the page returns you to exactly what you were looking at — becomes true
by construction, because the main window is never navigated away from; the alternative is a
flag in `AppModel` that has to be unwound correctly on every path out. The detail column's
`NavigationStack` is typed `[UUID]` and bound to `model.selection`, and the sidebar's `List`
selection is typed `URL?` and persisted to `UserDefaults` — a page that is neither an agent
nor a project would have to widen one of those to an enum, touching navigation that 004, 007,
009 and 011 all build on, for a read-only report. And a report you are reconciling against an
invoice is one you want *beside* the work, not instead of it; the figures move while it is
open.

**Alternatives considered**:

- *A page in the detail column.* Closest to the word "page" in the request, and rejected for
  the two costs above. Shown to the reader as a mock-up and not chosen.
- *A sheet.* Cheapest, and wrong: it blocks the window beneath it and reads as a dialogue
  demanding an answer rather than a report to sit with.
- *Putting it in Settings.* Settings is for what you set. This page sets nothing, and 010 is
  the feature that builds the app's first Settings scene.

---

## 7. Where the project total sits on the project page

**Decision**: A caption directly under the project name in `ProjectAgentsView.heading`, in the
slot beside the existing folder-is-gone warning.

**Rationale**: Confirmed with the reader. The heading is the one part of the project page that
is about the project rather than about the work in it, which is what the total is too. It
needs no new furniture, it is the first thing read, and it is inside the same 144pt gutter as
everything else on the page so the layout is unchanged. The caption names the period — the
figure alone could be mistaken for the sitting's total in the sidebar, which FR-022 forbids —
and carries a `.help` and an accessibility label saying what it counts.

**Alternatives considered**:

- *A line above the agent groups.* Keeps the heading to just the name, but separates the total
  from the thing it is a property of and adds a row of furniture to a page that is deliberately
  sparse.
- *The toolbar.* Always visible while scrolled, but furthest from the project it describes, and
  the toolbar in this app is for doing rather than reading.

---

## 8. The collision with 010 over the sidebar footer

**Decision**: 012 makes `SessionSpend` a button and leaves its text alone. 010 changes its
text and leaves its behaviour alone. Whichever lands second inherits the other's version.

**Rationale**: Both features want the twenty lines of `SessionSpend` in
`ProjectListView.swift`, and neither wants what the other wants. 010 replaces "This session"
with today's spend and its headroom, because a daily limit you cannot see approaching only
ever arrives as a surprise. 012 needs a fixed, obvious way into the Spending window, and a
line that already shows money is the one place a reader will look for more of it. The changes
are additive to each other: a button whose label is today's spend is a better door than a
button whose label is the sitting's.

**Alternatives considered**:

- *Sequence the features so one blocks the other.* Unnecessary; the seam is small, well
  understood and written down here.
- *Give the Spending window its own toolbar button in the sidebar.* A second affordance for a
  read-only report, in the column that is not about money, competing with the one "+" button
  the sidebar deliberately limits itself to.

---

## 9. Ordering, when there is more than one currency

**Decision**: One section per currency, each ordered by that currency's amount, largest first.
With a single currency — the ordinary case — there is one list and no section heading.

**Rationale**: This is the only genuinely awkward consequence of the app's refusal to convert.
"Ordered by spend, largest first" (FR-009) presumes a single ordering, and two currencies do
not have one: £100 and $120 cannot be ranked without a rate the app deliberately does not
have. Sectioning is the only answer that keeps both rules — each section has a total order
because it has one unit, and no figure is ever compared with a figure in another currency. It
also degrades to exactly the intended design in the common case, where there is nothing to
section.

**Alternatives considered**:

- *Order by the largest single amount across currencies.* Ranks £100 above $120 by numeric
  accident. A comparison the app has spent effort elsewhere refusing to make, smuggled into a
  sort key where nobody would look for it.
- *Order alphabetically by project.* Safe, and answers the wrong question. The page exists to
  say where the money went.
- *Pick a "main" currency and order by it.* Invents a hierarchy between currencies and buries
  the others.

---

## 10. No cache, no index, no stored total

**Decision**: Recompute on every call to `allProjects()` and on every render of the page.

**Rationale**: `allProjects()` is already O(agents) and is already called on every project
change; this adds a dictionary add per agent. The page is a fold over tens of summaries.
Against that, a cached total is a second copy of a fact that can disagree with the records,
must be invalidated on every agent change, archive, unarchive and delete, and would have to be
rebuilt at startup anyway from the records `loadAll()` decodes. SC-009 asks for no visible
wait with a year of agents on record, and the dominant cost in that scenario is the JSON
decode the daemon already does at launch, which this feature does not touch.

**Alternatives considered**:

- *A rolling total on disk.* This is close to what 010's `spend.json` must be, and the
  difference is instructive: 010 needs a ledger because a *day* is not derivable from the
  records (a day-stamped attribution has to be written when the money is spent). An all-time
  total is derivable, so writing it down would buy nothing and could be wrong.

---

## 11. The phone

**Decision**: No Remote view in this feature, but every rule in Core.

**Rationale**: The spec puts the phone out of scope, and `Remote/Sources/Chat/RemoteChatView.swift`
already shows an agent's own cost through the same `Cost.total(of:)`. Because `Spending` and
`Agent.isUnmeasured` live in `AgentsKitCore` — which builds for iOS — and because the two new
`ProjectSummary` fields arrive over the same `projects/list` the phone already calls, adding a
phone surface later is a view file and nothing else. No decision here forecloses it.
