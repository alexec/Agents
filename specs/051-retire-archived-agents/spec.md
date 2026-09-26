# Feature Specification: Retire Archived Agents

**Feature Branch**: `051-retire-archived-agents`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Retire archived agents. Archived agents are never deleted: archiving only moves state, and nothing removes the agent from the daemon, its directory, its transcript, or the per-agent maps the daemon keeps. Every agent is loaded at daemon start. Settle how long archived agents are kept (age and/or total size), whether retention can be turned off, whether a record stays as a tombstone while the transcript goes, what happens to worktrees and to events that name the agent, whether archived agents stay loaded in daemon memory at all, and trimming the per-agent daemon maps when an agent is archived. Archived agents can be unarchived and branched from, so deletion must respect that."

## Why this feature exists

Archiving an agent says *this is over*. It folds the chat out of the project's list and lets its
worktree go if everything in it was committed. It does not throw anything away. The agent's record,
its whole conversation and everything the daemon remembers about it stay where they were. They
stay in the daemon's memory as well, because every agent, archived or not, is loaded when the
daemon starts.

Measured on 2026-09-25, the real store held 283 agents in 814 MB. 263 of them were archived, and
those held 791 MB. The store was only seven days old, so it is growing by about 115 MB a day. 23
conversations were over 10 MB and the largest was 55 MB. A single agent's record, without its
conversation, was 22 KB, most of it the option and command lists the runtime advertised when it
started. Nothing in the app ever makes any of this smaller. A person who uses the app every day
will have gigabytes of conversations they will never open again within a month, and a daemon
that reads all of them in at every start.

This feature gives archived agents an end. An archived agent is kept whole, and can be unarchived
or branched from, for a set time. After that it is **retired**. Its conversation and the bulk of its
record are deleted. A small tombstone is left behind, so that everything that names the agent
(events, the agent that started it, the agents it started, a worktree, a project's costs) still has
something to name. The person chooses how long archived agents are kept, can cap how much space
they may take, and can turn retirement off.

The same work stops the daemon carrying archived agents it is not using. An archived agent is not
loaded in full until someone opens it, and archiving an agent lets go of everything the daemon was
holding in memory for it while it was live.

## Clarifications

### Session 2026-09-25

- Q: How long is an archived agent kept before it is retired? → A: 30 days after it was archived. There is also a cap on the total size of archived agents, 2 GB by default. When archived agents are over the cap, the ones archived longest ago are retired first until they are back under it.
- Q: Is retirement on by default, and can it be turned off? → A: It is on by default. The person can change the time and the cap in Settings, or choose to keep archived agents forever, which turns retirement off.
- Q: What does retiring an agent leave behind? → A: A small tombstone: its name, project, dates, cost, how it ended and who started it, so that anything that names the agent still resolves. The conversation and the rest of the record are deleted. A retired agent cannot be unarchived, opened as a conversation, or branched from.
- Q: Can the person pin one archived agent to keep it forever? → A: No. There is no per-agent pin. To keep an agent, the person unarchives it, or parks it (040), and retirement only ever touches archived agents.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Old archived agents go away by themselves (Priority: P1)

Someone uses the app every day and archives dozens of chats a week. They never think about disk
space. A month after they archived a chat, it is retired without them doing anything. Its
conversation is deleted and it disappears from the project's Archived list. The store stops
growing without bound, and the person never has to clear it by hand.

**Why this priority**: It is the whole point. Everything else in this feature either protects what
must not be lost or tidies what retirement leaves behind.

**Independent Test**: On a scratch store, archive an agent and move the clock forward 30 days.
Check that the agent's conversation and record are gone from disk, that it is no longer in the
Archived list, and that a tombstone for it remains. Check that an agent archived 29 days ago, and
every agent that is not archived, is untouched.

**Acceptance Scenarios**:

1. **Given** an agent archived 30 or more days ago and retirement set to its default, **When** the daemon next checks, **Then** the agent is retired: its conversation and full record are deleted and a tombstone is kept.
2. **Given** an agent archived less than 30 days ago, **When** the daemon checks, **Then** it is not retired, unless the size cap requires it (Story 2).
3. **Given** any agent that is not archived, including a parked, stopped or finished one, **When** the daemon checks, **Then** it is never retired, however old it is.
4. **Given** an archived agent is unarchived, **When** it is archived again later, **Then** its 30 days start again from the new archiving.
5. **Given** the daemon was not running when an agent's 30 days ran out, **When** it next starts, **Then** it retires that agent soon after starting. Starting is not held up while it does.
6. **Given** a retired agent, **When** the project's list is shown, **Then** the agent is not in the Archived list. The Archived heading's count leaves it out.

---

### User Story 2 - Archived agents never take more than a set amount of space (Priority: P1)

A heavy week of long-running agents can produce gigabytes of conversation. The age limit alone
would keep all of it for a month. The cap stops that. When archived agents together take more than
2 GB, the ones archived longest ago are retired, oldest first, until they are back under.

**Why this priority**: The measured rate is about 115 MB a day, so 30 days would already be about
3.4 GB. Without the cap the age limit does not bound the store.

**Independent Test**: On a scratch store with the cap set low, archive agents with large
conversations until the archived total passes it. Check that the agents archived longest ago are
retired one at a time until the total is under the cap, and that none archived in the last day is
retired.

**Acceptance Scenarios**:

1. **Given** archived agents that together take more than the cap, **When** the daemon checks, **Then** it retires archived agents in the order they were archived, oldest first, until the rest take no more than the cap.
2. **Given** an agent archived less than a day ago, **When** the cap would otherwise retire it, **Then** it is kept. An agent is never retired on the day it was archived, so an archive by mistake can always be undone.
3. **Given** the only archived agents left over the cap are ones that cannot be retired yet (archived under a day ago, or held by Story 5's rules), **When** the daemon checks, **Then** it retires nothing more, and Settings says the archived agents are over the cap and why.
4. **Given** the cap, **When** the size of archived agents is counted, **Then** it counts what retiring them would free: their conversations and records on disk. Agents that are not archived do not count toward it.

---

### User Story 3 - Choose how long, or keep them forever (Priority: P1)

The person opens Settings and finds where archived agents are kept. It says how many there are and
how much space they take, and offers how long to keep them and how much space they may take. One
choice is to keep them forever, which turns retirement off.

**Why this priority**: Retirement deletes things. The person has to be able to see that it is
happening and turn it off.

**Independent Test**: In Settings, change the time to 7 days and check that an agent archived 8
days ago is retired at the next check. Choose Keep forever and check that nothing is retired
however old or large archived agents get. Restart the app and the daemon and check the choices
are kept.

**Acceptance Scenarios**:

1. **Given** Settings, **When** the person opens it, **Then** it shows how many archived agents there are, how much space they take, how long they are kept and the size cap.
2. **Given** the time setting, **When** the person opens it, **Then** it offers 7 days, 14 days, 30 days (the default), 90 days and Forever.
3. **Given** the cap setting, **When** the person opens it, **Then** it offers 1 GB, 2 GB (the default), 5 GB, 10 GB and No limit.
4. **Given** the time is Forever and the cap is No limit, **When** the daemon checks, **Then** nothing is retired. Settings says that archived agents are kept forever.
5. **Given** the person shortens the time or lowers the cap, **When** the change would retire agents at once, **Then** Settings says how many would go and how much space that frees, and asks before it applies the change.
6. **Given** the settings, **When** the app or daemon restarts, **Then** they are unchanged.

---

### User Story 4 - See what is about to go, and bring it back in time (Priority: P2)

The person opens a project's Archived list to find an old chat. Chats close to retirement say so
("Retires in 3 days"). They find the one they want, unarchive it, and it is theirs again with its
whole conversation, for as long as they like. If they come looking after it has been retired, the
app tells them plainly that it was retired and when, instead of saying it cannot be found.

**Why this priority**: There is no pin and no undo after retirement. The warning and a clear
account of what happened are what make that bearable.

**Independent Test**: Archive an agent and move the clock to 27 days later. Check that its row says
it retires in 3 days. Unarchive it and check it is whole and no longer marked. Retire another, then
follow an event that names it and check the app says it was retired, and when.

**Acceptance Scenarios**:

1. **Given** an archived agent that will be retired by age within 7 days, **When** its row in the Archived list is shown, **Then** it says when it will be retired.
2. **Given** an archived agent that is the next to go under the cap, **When** its row is shown, **Then** it says it will be retired to keep under the cap.
3. **Given** an archived agent not yet retired, **When** the person unarchives it, **Then** it returns whole, with its full conversation, and can be prompted, branched and archived again as before this feature.
4. **Given** an archived agent not yet retired, **When** the person branches from it, **Then** the branch is a new agent with its own copy of the conversation, and retiring the original later does not touch the branch.
5. **Given** a retired agent, **When** anything in the app leads to it (an event, a "started by" line, a worktree, a link from the phone), **Then** the app says the agent was retired, names it, and says when it was archived and retired. It does not say "not found" or show an error.
6. **Given** a project's Archived list, **When** agents have been retired from it, **Then** the list ends with a line saying how many older agents have been retired.

---

### User Story 5 - Nothing that is still in use is retired (Priority: P2)

An archived agent can still matter. Its worktree may hold work that was never committed or merged.
A workflow run it belongs to may still be going. Retiring it would leave that work with no account
of how it came to be. Such an agent waits, and is retired once nothing needs it.

**Why this priority**: The conversation is the only record of why uncommitted work looks the way
it does. Deleting it while the work is still on disk loses something the person cannot get back.

**Independent Test**: Archive an agent whose app-made worktree has an uncommitted change. Move the
clock past 30 days and check it is not retired and its row says why. Commit and merge the change,
remove the worktree, and check the agent is retired at the next check.

**Acceptance Scenarios**:

1. **Given** an archived agent whose app-made worktree still exists with uncommitted changes or commits not merged anywhere else, **When** its time runs out, **Then** it is not retired. Its row says it is kept because its worktree has work in it.
2. **Given** an archived agent whose worktree is shared with an agent that is not archived (a branch of it, or one started in the same worktree), **When** its time runs out, **Then** it is retired, and the worktree is left alone for the other agent.
3. **Given** an archived agent whose app-made worktree still exists and is clean, **When** it is retired, **Then** the worktree is removed as archiving already removes it, and its branch is deleted only if it was merged.
4. **Given** a worktree the person made themselves, **When** the agent using it is retired, **Then** the worktree is never touched.
5. **Given** an archived agent that belongs to a workflow run that has not finished, **When** its time runs out, **Then** it is not retired until the run has finished.

---

### User Story 6 - The daemon stops carrying archived agents it is not using (Priority: P2)

The daemon starts quickly and stays small however many agents have been archived. An archived agent
is listed from a short summary. Its full record and conversation are read only when someone opens
it, unarchives it or branches from it. When an agent is archived, the daemon lets go of everything
it held in memory for the agent while it was live.

**Why this priority**: Most of the store is archived agents. Reading all of them at every start
makes starting slower and the daemon bigger for no benefit, and does so even for a person who
turns retirement off.

**Independent Test**: On a scratch store with 1,000 archived agents and 10 live ones, start the
daemon and check it is ready as quickly, and takes nearly as little memory, as the same store with
only the 10 live ones. Open one archived agent and check its conversation shows. Archive a live
agent that has held changes, file interests and cost readings, and check the daemon holds none of
them for it afterwards.

**Acceptance Scenarios**:

1. **Given** a store with many archived agents, **When** the daemon starts, **Then** it reads only a summary of each archived agent: enough to list it, count it, size it and say when it will be retired.
2. **Given** an archived agent, **When** the person opens it, unarchives it or branches from it, **Then** the daemon reads its full record and conversation then, and the person sees no difference from today apart from the time the read takes.
3. **Given** an archived agent opened for reading, **When** no window has looked at it for a while, **Then** the daemon lets go of it again.
4. **Given** a live agent, **When** it is archived, **Then** the daemon lets go of everything it held in memory for that agent while it was live: its held changes, file interests, cost readings, plan files shown, shell watchers, credential offers and loans, and the rest. What unarchiving needs is read back from the record.
5. **Given** an agent that was archived in the middle of a turn, **When** that turn's work unwinds after the archive, **Then** the work still sees that the agent was stopped and archived and does nothing further, exactly as today. Letting go of memory must not let stale work act on an archived agent.

---

### User Story 7 - Retire an archived agent now (Priority: P3)

The person knows a big archived conversation is of no further use and wants the space back today.
They open the archived agent's menu, choose Retire now, confirm, and it is retired at once.

**Why this priority**: The automatic rules cover the common case. This is for the person who is
short of space or tidying on purpose.

**Independent Test**: Choose Retire now on an archived agent, confirm, and check it is retired at
once. Check that Retire now is not offered on an agent that is not archived, or on one Story 5
holds.

**Acceptance Scenarios**:

1. **Given** an archived agent, **When** the person opens its menu, **Then** Retire now is offered.
2. **Given** Retire now is chosen, **When** the confirmation says what will be deleted and that it cannot be undone, **And** the person confirms, **Then** the agent is retired at once.
3. **Given** an agent that is not archived, **When** its menu is opened, **Then** Retire now is not offered.
4. **Given** an archived agent held by Story 5's rules, **When** its menu is opened, **Then** Retire now is disabled, with the reason as its tooltip.

---

### Edge Cases

- **The first start after this feature ships.** Agents archived before it have no record of when they were archived. Their 30 days count from the first time the daemon starts with this feature, so nothing disappears on the day it ships. The cap still applies, but only after the one-day floor, and among them the one idle longest goes first.
- **The clock moves backwards, or jumps forwards.** An agent is retired only when both its archive time and the time since it are sane. An archive time in the future counts as now. A jump forwards of more than a day retires nothing by age until a day of real time has passed, so a mis-set clock cannot empty the archive at once.
- **Retirement is interrupted** (the daemon is killed, or the Mac sleeps, halfway). Retiring an agent either finishes or can be finished at the next start. The store is never left with a tombstone and a conversation, or with neither.
- **A window has the agent open when it is retired.** Only archived agents are retired, and a window showing one is reading it. The agent is not retired while a window has it open. It is retired at the next check after the window lets go.
- **The phone is looking at an archived agent.** Same as a window on the Mac.
- **Events that name the agent.** Events already carry the agent's name as it was, so the events list reads the same after retirement. Following an event to a retired agent shows the retired page (Story 4). Workflow triggers that name the agent are not changed.
- **An agent started by a retired agent.** Its "started by" line still names the starter, from the tombstone, and says it was retired.
- **A retired agent that started live agents.** Retiring it does not touch the agents it started.
- **Costs and spending.** The daily spending totals are kept separately and are not changed by retirement. A project's cost total still counts the retired agent's cost, which the tombstone keeps.
- **A branch of an archived agent.** A branch has its own copy of the conversation from the moment it is taken, so retiring the original leaves the branch whole.
- **The runtime's own copy of the conversation** (for example, a runtime's session files under the person's home). Retirement does not touch files the runtime keeps for itself. It deletes only what the app stores.
- **Agents on a server** (037). A server's agents are kept by the daemon on that server. The same rules apply there, with the settings the Mac has.
- **An archived project** (a project archived as a whole). Its agents are archived agents and are retired by the same rules.
- **Retirement is turned off and back on.** Turning it back on applies the rules to everything archived, and asks first if that would retire agents at once (Story 3, scenario 5).
- **An agent archived by another agent or by itself** (028, the finish_turn archive ask). It is archived like any other and retired by the same rules.
- **Disk full.** If the store cannot be written, retirement deletes nothing, because it cannot write the tombstone first. It tries again at the next check.

## Requirements *(mandatory)*

### Functional Requirements

**Retention**

- **FR-001**: The daemon MUST record when each agent was archived. Unarchiving MUST clear it, and archiving again MUST set it again.
- **FR-002**: The daemon MUST retire an archived agent once the time it has been archived passes the person's setting (default 30 days), subject to FR-006 and FR-007.
- **FR-003**: When the archived agents' total size on disk is above the person's cap (default 2 GB), the daemon MUST retire archived agents in the order they were archived, oldest first, until the total is at or under the cap, subject to FR-006 and FR-007.
- **FR-004**: The daemon MUST check at start, soon after, and at least every hour while it runs. Checking and retiring MUST NOT hold up starting, listing agents or running agents.
- **FR-005**: Only archived agents MUST ever be retired. Agents that are working, finished, stopped, parked or in any other state MUST never be retired, however old or large.
- **FR-006**: An agent archived less than 24 hours ago MUST NOT be retired by age, by the cap or by the clock jumping.
- **FR-007**: An archived agent MUST NOT be retired while its app-made worktree exists with uncommitted changes or unmerged commits, while a workflow run it belongs to has not finished, or while a window on any device has it open. It MUST be retired at the first check after the reason goes.
- **FR-008**: Agents archived before this feature MUST be treated as archived at the first daemon start that has it.

**Settings**

- **FR-009**: Settings MUST show the number of archived agents, the space they take, the time they are kept (7, 14, 30, 90 days or Forever; default 30) and the cap (1, 2, 5, 10 GB or No limit; default 2 GB).
- **FR-010**: Forever and No limit together MUST turn retirement off. Settings MUST then say that archived agents are kept forever.
- **FR-011**: A change to either setting that would retire agents at once MUST first say how many and how much space, and apply only when the person confirms.
- **FR-012**: The settings MUST be kept by the daemon, survive restarts, and apply to the Mac's own daemon and to every server's daemon.
- **FR-013**: When archived agents are over the cap and nothing more can be retired, Settings MUST say so and why.

**Retiring and the tombstone**

- **FR-014**: Retiring an agent MUST delete its conversation and every file the app keeps for it, and MUST replace its record with a tombstone.
- **FR-015**: The tombstone MUST keep the agent's id, title, project, runtime, host, the times it was created, last active, archived and retired, how it ended and why it was archived, its total cost, the workflow, run or agent that started it, and the name and branch of its worktree. It MUST keep nothing else, and MUST be under 2 KB.
- **FR-016**: A retired agent MUST NOT be offered for unarchiving, prompting, branching or opening as a conversation, on any device or through any agent tool.
- **FR-017**: Retiring MUST write the tombstone before deleting anything, and MUST be finished at the next start if it was cut off. At no point MUST the agent be both absent and without a tombstone.
- **FR-018**: A clean app-made worktree still on disk MUST be removed on retirement by the same rule archiving uses, with the branch deleted only if merged. A worktree the person made, or one used by an agent that is not archived, MUST NOT be touched.
- **FR-019**: Retirement MUST NOT delete or change the runtime's own files, the event log, the daily spending totals, or any other agent.
- **FR-020**: The person MUST be able to retire an archived agent at once from its menu, after a confirmation that says what is deleted and that it cannot be undone. Retire now MUST be disabled with a reason for an agent FR-007 holds.

**What names a retired agent**

- **FR-021**: Anything that names a retired agent (an event, a "started by" line, a worktree, a project's costs, a link) MUST resolve to the tombstone, and MUST show that the agent was retired, with its name and when. It MUST NOT show "not found" or an error.
- **FR-022**: Retired agents MUST NOT appear in a project's Archived list or its count. The list MUST end with a line saying how many agents have been retired from it.
- **FR-023**: An archived agent's row MUST say when it will be retired once that is within 7 days, or that it is next to go under the cap, or why it is being kept (FR-007).

**Daemon memory**

- **FR-024**: At start the daemon MUST read only a summary of each archived agent: enough to list, count, size and schedule it. It MUST read the full record and conversation only when the agent is opened, unarchived or branched from.
- **FR-025**: The daemon MUST let go of a fully read archived agent when no window has looked at it for a while.
- **FR-026**: On archiving an agent, the daemon MUST drop everything it holds in memory for it as a live agent, and MUST keep only its summary. Unarchiving MUST rebuild what a live agent needs from the record.
- **FR-027**: Dropping an archived agent's memory MUST NOT let work that is still unwinding from before the archive act on the agent. The guard that tells stale work the agent was stopped MUST hold after the memory is gone, and after a daemon restart.
- **FR-028**: The phone and iPad MUST show retirement warnings, the retired page and the retired count as the Mac does. They MUST NOT offer the settings or Retire now in this feature.

### Key Entities

- **Archive time**: when an agent was last archived. It is the start of its retention, and is cleared on unarchiving.
- **Archived summary**: what the daemon holds for an archived agent it has not been asked to open: id, title, project, archive time, last activity, size on disk, and whether anything holds it (FR-007). It is enough to list the agent and decide when to retire it.
- **Tombstone**: what is left of a retired agent (FR-015). It is small and permanent, and is what anything that names the agent resolves to.
- **Retention settings**: the time archived agents are kept and the size cap they may take, kept by the daemon. Forever and No limit together mean retirement is off.
- **Hold**: a reason an archived agent is past its time but is not yet retired: work in its worktree, an unfinished workflow run, or a window reading it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With default settings and the measured rate of use, the space archived agents take on disk stays under 2 GB plus one day's archiving, instead of growing without end.
- **SC-002**: No agent that is not archived is ever retired, and no agent is retired within 24 hours of being archived. That is zero across repeated trials that include clock changes and restarts.
- **SC-003**: The daemon starts, and is ready to list agents, within 10% of the time it takes on the same store with no archived agents, for stores of up to 1,000 archived agents.
- **SC-004**: The daemon's memory with 1,000 archived agents is within 20 MB of the same store with none.
- **SC-005**: Following any link to a retired agent shows who it was and when it was retired. That is 100% of events, "started by" lines and worktrees tried, with no errors.
- **SC-006**: Interrupting retirement at any point, by killing the daemon, never leaves an agent that is gone without a tombstone, or a tombstone beside a conversation. That is zero across repeated trials.
- **SC-007**: A person who never opens Settings never has to clear old agents or free space by hand to keep the app working.

## Assumptions

- The default cap of 2 GB is below what 30 days would take at the measured rate (about 3.4 GB), so for a heavy user the cap retires agents before their 30 days are up. That is intended: the age is how long an agent can be kept, and the cap is what bounds the store. The person can raise the cap.
- Tombstones are kept for good. At under 2 KB each, a year of heavy use is a few tens of megabytes. Removing them can come later if it ever matters.
- Size is counted from what the app stores for the agent on disk, which is almost all conversation. The runtime's own copies of the conversation are not counted and are not deleted.
- "A while" for letting go of an opened archived agent (FR-025) is left to the plan. Minutes, not hours.
- A retired agent's tombstone is not shown anywhere of its own. It is only reached through something that names it, and through the retired count in the Archived list.
- The hourly check is often enough. Nothing depends on an agent being retired within the hour its time runs out.
- The per-agent memory the daemon drops on archiving (FR-026) is everything it keeps per agent for a live agent. The plan lists it field by field from the daemon as it is then, since the list grows with every feature.
- Parking (040) is the way to keep a chat around without it counting as over. Archiving means over, and retirement follows from that.
