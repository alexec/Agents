# Feature Specification: Cost Totals

**Feature Branch**: `012-cost-totals`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "Cost controls UX. I want to be able to see the total cost of a project and the grand total cost. The latter would need to be a new page. The former just a total on the project page."

## Summary

The app already knows what every agent has cost, and shows it in two places: on the agent
being read, and as what this sitting has cost since the window opened. Neither answers the
question somebody actually asks when the bill arrives, which is *where did it go*. This
feature adds the two totals that answer it — what one project has cost, on that project's
own page, and what everything has cost, on a page of its own that names every project's
share.

It reports. It does not cap: 010 is the feature that stops spending, and this one is the
feature that tells you what was spent. The two are usable apart and better together.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - What has this project cost? (Priority: P1)

Someone has been running agents against one repository for a fortnight. They can see what
the chat they have open cost, and they can see what today's sitting cost, and from those
two numbers they cannot work out the thing they want to know: what this piece of work has
cost them in total. Today the only way is to open every chat in the project, including the
archived ones, and add up by hand. They want the figure to be on the project page, where
the project already is.

**Why this priority**: It is the smaller half of the request and the one that needs no new
surface at all — the page exists, the agents are already on it, and the number is a sum of
figures the app already keeps. It is also the total people look for first, because a
project is the unit work is actually thought about in. Shipping only this already turns a
scatter of per-chat figures into one answer.

**Independent Test**: Open a project with several agents, some finished and some archived.
Read one figure off the project page. Add up by hand what each of its chats says it cost
and confirm the two agree.

**Acceptance Scenarios**:

1. **Given** a project with agents that have spent, **When** the reader opens the project page, **Then** one figure says what the project has cost in total, without their opening a chat or doing arithmetic.
2. **Given** a project whose agents include finished and archived ones, **When** the total is shown, **Then** what those agents spent is in it, because the money was spent whether or not the conversation is still on screen.
3. **Given** an agent in the project spends while the page is open, **When** the runtime reports it, **Then** the figure on the page moves without the reader leaving the page and coming back.
4. **Given** a project in which nothing has been spent, **When** the reader opens it, **Then** no figure is shown at all, rather than a zero.
5. **Given** agents in a project that reported cost in two currencies, **When** the total is shown, **Then** each currency is its own figure and the two are neither added together nor converted.
6. **Given** a project containing an agent on a runtime that reports no cost, **When** the total is shown, **Then** the reader can tell the total leaves something out rather than being led to read it as the whole.

---

### User Story 2 - What has all of it cost? (Priority: P2)

Someone wants the figure they would compare against the invoice: everything the app has
ever spent, across every project. And having seen it, the immediate next question is where
it went — which project ate it. They want a page that says both: the grand total, and every
project's share of it, biggest first.

**Why this priority**: It is the other half of the request and the one that needs the new
page. It sits below Story 1 because the per-project total is what people reach for daily
and because the grand total is far more useful once each project's figure is already
established and trusted — the page is, in effect, those same figures gathered and ordered.

**Independent Test**: Spend in two or three projects. Open the new page. Confirm the grand
total is there, that each project is listed with its own figure, that those figures are the
same ones the project pages show, and that they add up to the grand total exactly.

**Acceptance Scenarios**:

1. **Given** spend across several projects, **When** the reader opens the new page, **Then** the grand total is the first thing on it and is the total of everything the app has on record.
2. **Given** the page is open, **When** the reader reads down it, **Then** every project that has spent anything is named with its own figure, largest first, so the biggest spender is the one at the top.
3. **Given** a project listed on the page, **When** the reader compares its figure with the figure on that project's own page, **Then** the two are the same.
4. **Given** the figures listed, **When** they are added up per currency, **Then** they come to the grand total exactly, with nothing unaccounted for.
5. **Given** the page is open, **When** an agent spends, **Then** both the grand total and that project's line move.
6. **Given** the reader is on the page, **When** they leave it, **Then** they are returned to whatever they were looking at before, with the project and chat they had open unchanged.
7. **Given** spend in more than one currency, **When** the page is read, **Then** each currency is its own total and its own column of shares, and nothing is converted or combined.

---

### User Story 3 - The total is the whole bill, and says so when it is not (Priority: P3)

Someone reconciling the page against an invoice needs to trust it. That means the awkward
spend has to be in it — the project they archived last month, the chat they archived last
week, the agent a workflow started in a folder that was never added as a project — and it
means the page has to admit what it cannot see, rather than presenting a figure that looks
complete and is not.

**Why this priority**: The two totals are readable without this and will be right in the
ordinary case, which is why it sits last. But a total that quietly omits the archived half
of the work is worse than no total, because it will be believed. This is the story that
makes the other two worth trusting rather than merely worth reading.

**Independent Test**: Spend in a project, archive an agent in it, then archive the project.
Start an agent in a folder that is not a project at all and let it spend. Confirm the grand
total has not moved down at any point, that the archived project is still named and marked
as archived, and that the spend belonging to no project is named somewhere rather than
missing.

**Acceptance Scenarios**:

1. **Given** an agent that is archived, **When** the totals are worked out, **Then** what it spent is still counted, in its project and in the grand total.
2. **Given** a project that is archived, **When** the reader opens the page, **Then** it is still listed with its figure, and it is evident that it is archived.
3. **Given** spend by an agent whose folder is not a project the reader has added, **When** the page is read, **Then** that spend is in the grand total and is named on the page, rather than being silently left out or silently folded into somebody else's project.
4. **Given** a project folder that has been deleted from disk, **When** the page is read, **Then** the project is still listed with what it spent, because the spend happened.
5. **Given** agents on a runtime that reports no cost, **When** the page is read, **Then** it says that some agents could not be measured and how many, so the grand total reads as a floor rather than as the whole.
6. **Given** nothing has ever been spent, **When** the reader opens the page, **Then** it says so plainly rather than showing a row of zeroes.

---

### Edge Cases

- **Two currencies.** A grand total is the one place somebody will be most tempted to see a
  single number, and it is the one place the app must most firmly refuse. Nothing is
  converted and nothing is added across currencies, anywhere: two currencies are two
  totals, each with its own list of shares.
- **A runtime that reports no cost.** Cost is the runtime's own figure and some runtimes
  send none. Every total in this feature is therefore a floor rather than a fact whenever
  such an agent has run, and the page must say so instead of letting the figure imply
  completeness.
- **Spend belonging to no project.** An agent can be started in a folder the reader never
  added to their list of projects, and a workflow can do it without anybody typing. That
  money is real and is in the grand total; it needs a name on the page so the shares still
  add up.
- **An agent in a folder inside a project.** An agent's folder is the one it was started
  in, and a project is a folder. An agent is counted in the project whose folder is exactly
  its own; one started in a subfolder that is not itself a project is spend belonging to no
  project, and is treated as such rather than being guessed into its parent.
- **Records deleted by hand.** The app's totals are sums of the records it still holds.
  Deleting an agent's record removes what it spent from every total. This is a ledger of
  what the app can see, not an account of what was billed, and the difference matters when
  somebody reconciles.
- **A very long list of projects.** The page is a list of projects rather than of agents,
  which keeps it short, but somebody who has been at this for a year will still have many.
  Ordering by spend means the answer to *where did it go* is at the top whatever the length.
- **A project renamed by being moved.** A project is named by its folder, and a folder that
  moves reads as a different project. The old one keeps its spend and stays on the page.
- **Cost arriving after an agent has ended.** A final figure can arrive once an agent is
  finished or archived. It joins the totals when it arrives.
- **Nothing spent.** A project that has spent nothing shows no figure and is not listed on
  the page; an app that has spent nothing says so in a sentence rather than showing zero.
- **A sitting that is not the whole story.** The app already shows what this sitting cost,
  which starts from zero every time the window opens. That figure and these totals will
  disagree, always, and each must be labelled well enough that nobody reads one as the other.

## Requirements *(mandatory)*

### Functional Requirements

**The project total**

- **FR-001**: The project page MUST show what that project has cost in total, in one figure
  per currency, without the reader opening a chat or adding anything up.
- **FR-002**: The project's total MUST be everything spent by every agent whose folder is
  that project, over the whole life of each agent, including agents that have ended and
  agents that have been archived.
- **FR-003**: The total MUST be shown per currency, and the app MUST NOT convert between
  currencies or add them together.
- **FR-004**: Where nothing has been spent in a project, the app MUST show no figure rather
  than a zero.
- **FR-005**: The figure MUST follow spend as it is reported, while the page is open,
  without the reader navigating away and back.
- **FR-006**: Where a project contains an agent whose runtime reports no cost, the project's
  total MUST be presented as incomplete rather than as the whole.

**The grand total page**

- **FR-007**: The app MUST have a page whose subject is cost, reachable from the main window
  in a fixed place, without the reader first selecting a project.
- **FR-008**: The page MUST show the grand total: everything the app has on record, spent by
  every agent, in every project and outside any project, per currency.
- **FR-009**: The page MUST list every project that has spent anything, with that project's
  own total, ordered by spend with the largest first.
- **FR-010**: A project's figure on the page MUST be the same figure that project's own page
  shows.
- **FR-011**: The figures listed on the page MUST add up to the grand total exactly, per
  currency, with nothing omitted and nothing counted twice.
- **FR-012**: Spend by agents that belong to no project MUST be included in the grand total
  and MUST be named on the page as its own entry, rather than omitted or attributed to a
  project that did not incur it. *(Planning found this category cannot be populated: the
  project list is the union of every folder an agent has run in with every kept record, so an
  agent in an unadded folder creates a derived project rather than falling outside one. The
  requirement is satisfied by construction and is discharged by the FR-011 invariant test, not
  by an "Other" row — see [research.md §3](./research.md).)*
- **FR-013**: Archived projects MUST be listed with their spend, and MUST be distinguishable
  from projects that are not archived.
- **FR-014**: A project whose folder is no longer on disk MUST still be listed with its
  spend.
- **FR-015**: The page MUST state when some spend could not be measured, and how many agents
  that is, so the grand total is not read as complete when it is not.
- **FR-016**: The page MUST follow spend as it is reported while it is open.
- **FR-017**: Where nothing has ever been spent, the page MUST say so plainly rather than
  showing zeroes.
- **FR-018**: Leaving the page MUST return the reader to what they were looking at, with the
  project and chat they had open unchanged.
- **FR-019**: The page MUST be read-only. Nothing on it MUST start, stop, archive, or delete
  anything, and no agent, workflow, or tool served to an agent MUST be able to change what
  it reports.

**Both**

- **FR-020**: Every total MUST be derived from the records the app already keeps, and MUST
  therefore be the same after the app, the daemon, or the machine is restarted.
- **FR-021**: Every total MUST be the runtime's own reported cost. The app MUST NOT
  estimate, MUST NOT price tokens itself, and MUST NOT convert currencies.
- **FR-022**: The totals in this feature MUST be labelled so that none of them can be
  mistaken for the existing figure for the current sitting, nor that figure for one of them.

### Key Entities

- **Project total**: What every agent whose folder is this project has spent over its whole
  life, per currency, including ended and archived agents. Belongs to the project, not to
  the window, and does not reset.
- **Grand total**: Every project total added to the spend that belongs to no project, per
  currency. The figure somebody compares with an invoice, and the reason the shares beneath
  it must add up to it exactly.
- **Unassigned spend**: What agents in folders that are not projects have cost. Part of the
  grand total, named on the page, and the reason the shares add up.
- **Unmeasured spend**: What agents on runtimes that report no cost have spent, which is
  unknowable. Never zero, never estimated, and the reason every total here is a floor.
- **The sitting's cost**: The figure the app already shows, which starts at zero when the
  window opens. Not one of the above, and must never be confused with one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reader can answer *what has this project cost* in one look at the project
  page, with no arithmetic and without opening a chat.
- **SC-002**: A reader who has not seen the new page before finds it in under ten seconds
  and needs no documentation to read it.
- **SC-003**: For every currency, the figures listed on the page add up to the stated grand
  total exactly.
- **SC-004**: For every project, the figure on the page and the figure on that project's own
  page are identical.
- **SC-005**: Archiving an agent or a project does not change any total. In testing, no
  total falls as a result of archiving.
- **SC-006**: No figure anywhere in the app combines or converts currencies. In testing,
  spend in two currencies is always shown as two figures.
- **SC-007**: Restarting the app, the daemon, and the machine leaves every total unchanged.
- **SC-008**: Where any agent on record reported no cost, every total that includes it is
  described as incomplete. In testing, no such total is presented as the whole.
- **SC-009**: The page appears with its figures filled in without a visible wait, with a
  year's worth of agents on record.
- **SC-010**: No sequence of actions by an agent or a workflow changes what any total
  reports.

## Assumptions

- **Both totals are all-time.** "Total cost of a project" and "grand total cost" read as
  everything ever spent, and that is what is built. Date ranges, month-to-date, spend over
  time, and charts are out of scope. 010 covers the current day's spend against a daily
  limit, and this feature does not duplicate or replace it.
- **The new page lists projects, not agents.** A per-agent breakdown already exists — the
  project page lists a project's agents and the meter in each chat says what that agent
  cost — and repeating it on the grand total page would make it long without making it
  more useful.
- **Ordering by spend, not by name or recency.** The question the page answers is where the
  money went, and that answer should be at the top.
- **The figures are the ones the app already keeps.** Cost is the runtime's own reported
  figure, summed per currency per agent, as the app does today. Nothing new is measured, no
  token is priced, and no currency is converted. It follows that a runtime which reports
  nothing can never be totalled, and the feature says so rather than showing zero.
- **The totals are a ledger of records held, not of money billed.** Deleting an agent's
  record lowers the totals. The app documents how to delete records, so this will happen,
  and the feature does not pretend otherwise.
- **No limits, no budgets, no alerts here.** This feature reports. Capping spend, warning
  before a cap, and per-day ceilings are 010's subject. If 010 ships, its limits and
  headroom appear where it says; nothing in this feature sets or changes a limit.
- **macOS first.** The project total and the new page are the Mac window. The phone is out
  of scope for this feature and continues to show what it shows today.
- **Per-project limits remain out of scope**, as 010 already assumed. Seeing a project's
  total does not imply being able to cap it, and this feature deliberately does not add
  that.
- **The project constitution is currently an unfilled template**, so no project-specific
  principles constrain this specification.
