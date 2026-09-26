# Feature Specification: Events and Waiting

**Feature Branch**: `042-events-and-waiting`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "An even richer events system. Agents can subscribe to events when things happen, this allows them to wait on events. They would need (a) a tool to do this and (b) a set of useful events to subscribe to. The user will need a way to see what events occurred in the system. Events are likely to be global (e.g. mac.wake or pull_request.changed). While we're at it we should review the current events we have. Events and workflows should work in harmony."

## Clarifications

### Session 2026-09-25

- Q: Can agents publish their own events, or only subscribe to the ones the app raises? → A: Both. The app raises its own events, and agents can also publish named events that other agents and workflows can wait on. Scripts, git hooks and webhooks raising events are out of scope for this version.
- Q: Where can the person see the events that happened? → A: On the Mac and on phone/iPad. The Mac gets a full events page. Phone and iPad get a read-only list, as Spending does.

## Where this starts from

Today "event" means two different things, and neither of them is something a person or an agent can look at.

1. **Workflow triggers** (008, 038). There are nine: `schedule`, `agent-finished`, `agent-asked-permission`, `agent-asked-form`, `agent-stopped`, `workflow-completed`, `pull-request-checks-failed`, `pull-request-review-comments` and `pull-request-conflicts`. They exist only while a workflow is being matched. The only trace they leave is each workflow's latest outcome, and nobody can wait on one except by writing a workflow.
2. **Window notifications** (`agent/changed`, `leases/changed`, `wake/changed`, and others). These keep screens up to date. They are too fine-grained to be events a person cares about. For example, `agent/changed` arrives on every token.

The review of the current set found these problems:

- **No waiting.** An agent that needs "when CI goes green", "when main moves" or "when the Mac wakes" either polls, which costs tokens, or gives up. The only real wait an agent has is a lease line (036) and `finish_turn`'s `blocked` on other agents. These are two private mechanisms for the same idea.
- **No record.** After a night of workflows, the person cannot answer "what happened, and what did the app do about it?" Each workflow's row shows one latest outcome and nothing more (008 FR-028).
- **Inconsistent names.** Trigger names are hyphenated (`agent-finished`). The names people reach for are dotted (`mac.wake`, `pull_request.changed`). The pull-request triggers only travel between devices by pretending to be unrecognised (038 R11).
- **Gaps.** Several things the app already knows raise no trigger: an agent becoming blocked (039), a lease coming free (036), the Mac sleeping and waking (024), the person going away and coming back, a daily cost limit being reached, a pull request being approved, merged or closed, the project's main branch moving, and a server going offline (037).
- **Ambiguity.** `agent-stopped` covers both "the person stopped it" and "it failed". Those call for different responses.

This feature makes an **event** one thing: a named, recorded fact that something happened. Workflows trigger on events, agents wait on them, and the person reads them.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent waits for something to happen, then carries on (Priority: P1)

An agent has pushed a pull request and needs its checks to pass before it can continue. Instead of polling or giving up, it waits on `pull_request.checks_passed` or `pull_request.checks_failed` for that pull request. Its turn ends, and it costs nothing while it waits. When one of those events happens, the app starts the agent again with a prompt that says which event happened and what it carries. The agent carries on from there.

**Why this priority**: This is the capability asked for, and it is useful even with a small set of events. Nothing else here matters until an agent can wait.

**Independent Test**: Have an agent wait on a custom event, or on `agent.finished` for a second agent. Confirm that the first agent's turn ends and that it shows as waiting, naming the event. Make the event happen. Confirm that the first agent is started again within seconds, with the event in its prompt.

**Acceptance Scenarios**:

1. **Given** an agent in a turn, **When** it asks to wait on one or more events, **Then** the wait is recorded, and the agent is told what it is waiting on and that it may end its turn.
2. **Given** a matching event happens while the request is still held open, **When** the wait is satisfied, **Then** the request returns the event directly and the agent carries on in the same turn.
3. **Given** no matching event happens within the time a request can be held open, **When** that limit is reached, **Then** the request returns saying the agent is still waiting, and the wait stays in place.
4. **Given** an agent whose turn has ended while waiting, **When** a matching event happens, **Then** the app starts the agent again with a prompt naming the event, when it happened, and its details. The prompt appears in the transcript like any prompt the app sends.
5. **Given** a wait with a deadline, **When** the deadline passes with no match, **Then** the agent is started again and told that the wait timed out.
6. **Given** a waiting agent, **When** the person looks at its chat or card on any device, **Then** it shows as waiting, and says on what and since when.
7. **Given** a waiting agent, **When** the agent cancels the wait, the person cancels it, or the agent is stopped, archived or prompted by the person, **Then** the wait ends and nothing resumes the agent later.
8. **Given** an agent that checked a condition and then waits, **When** the event happened between the check and the wait, **Then** the wait still catches it, because the agent can wait "from" an earlier point it was given.

---

### User Story 2 - The person sees what happened and what came of it (Priority: P2)

The person comes back after a few hours away. They open the events page. Newest first, it lists what happened: the Mac woke, pull request #41's checks failed, the babysitting workflow fired on it, an agent it started published `build.green`, a waiting agent woke on that, and main moved. For each event they can see which workflows fired or were refused and which waiting agents were woken. They can go from any of those to the agent concerned.

**Why this priority**: Without it, waiting and workflows are invisible. When a wait never ends, or a workflow never fires, the person has no way to tell whether the event didn't happen or the app didn't act on it.

**Independent Test**: Cause three different events, one of which fires a workflow and one of which wakes a waiting agent. Open the events page on the Mac and on the phone. Confirm that all three are listed with times and plain-language descriptions, and that the consequences are shown and lead to the agents concerned.

**Acceptance Scenarios**:

1. **Given** events have happened, **When** the person opens the events page, **Then** they see the events newest first. Each shows its time, name, a plain-language sentence, and the project it belongs to, or "This Mac".
2. **Given** an event that fired a workflow, had a workflow refuse it, or woke an agent, **When** the person looks at its row, **Then** those consequences are listed with it, and each one leads to its agent or workflow.
3. **Given** many events, **When** the person filters by project or by kind of event, **Then** only those events are shown.
4. **Given** the events page is open, **When** a new event happens, **Then** it appears without a refresh.
5. **Given** a phone or iPad, **When** the person opens the events list, **Then** they see the same events and consequences, read-only.
6. **Given** a workflow's row on the project page, **When** the person looks at it, **Then** they can go from its latest outcome to the event that caused it.

---

### User Story 3 - Workflows and waits use the same events (Priority: P3)

The person writes a workflow on `pull_request.merged`, and an agent waits on `pull_request.merged` for one pull request. Both use the same name, the same details, and the same list of what exists. Every existing workflow file keeps working unchanged. `agent-finished` is still understood, and the page describes it in the same words as `agent.finished`. Any event in the catalogue can trigger a workflow, including the new ones and ones that agents publish.

**Why this priority**: The person asked for events and workflows to work in harmony. Two vocabularies would drift. A workflow that fires on something an agent cannot wait on, or the other way round, is exactly that drift.

**Independent Test**: Take an existing workflow file with an old trigger name and confirm it fires exactly as before. Write a workflow on `mac.wake` and another on a custom event, and confirm that both fire and both show in the events log as consequences.

**Acceptance Scenarios**:

1. **Given** a workflow file that uses any of today's nine trigger names, **When** the app reads it, **Then** it behaves exactly as before, and the file is not rewritten.
2. **Given** a workflow whose trigger names any event in the catalogue, optionally narrowed by details (for example, one pull request or one custom event name), **When** that event happens, **Then** the workflow fires under all the rules it follows today: chain depth, one run at a time, archiving, and ceilings.
3. **Given** an agent listing the events it can wait on, and the workflow tool describing the triggers it can write, **When** both lists are compared, **Then** they are the same catalogue.
4. **Given** an agent that ends its turn as `blocked` on other agents, **When** the person looks at it, **Then** it shows as waiting in the same way as an agent waiting on `agent.finished` for those agents.

---

### User Story 4 - Agents signal each other with events they publish (Priority: P4)

An agent that builds and tests a branch publishes `custom.build_green` with a short message when it succeeds. Another agent, waiting on that event, wakes and merges. A workflow on `custom.release_ready` starts the release checklist. The person sees each publish in the log, with the agent that published it.

**Why this priority**: Agents can already start and wait on other agents (028). Publishing lets them coordinate by what happened, rather than by who happened to be running. It builds on stories 1 to 3.

**Independent Test**: Have agent A wait on `custom.ping`. Have agent B publish `custom.ping` with a message. Confirm that A wakes with B's message and that the log shows the publish, attributed to B, with A woken as its consequence.

**Acceptance Scenarios**:

1. **Given** an agent, **When** it publishes an event with a name and an optional short message and details, **Then** the event is recorded in its project, under the custom namespace, and attributed to that agent.
2. **Given** a published event, **When** agents in the same project are waiting on it, or workflows in that project trigger on it, **Then** they respond as they do to any other event.
3. **Given** an agent publishing too often, **When** it passes the publish limit, **Then** further publishes are refused and it is told why.
4. **Given** an agent started by a workflow, **When** it publishes an event that fires another workflow, **Then** that fire counts as one deeper in the chain, so a publish loop is stopped by the chain-depth limit.
5. **Given** an agent, **When** it tries to publish under an app-owned name (such as `mac.wake` or `agent.finished`), **Then** it is refused.

---

### User Story 5 - The machine and the person are events too (Priority: P5)

A workflow runs "when the Mac wakes", to catch up on what happened overnight. An agent that needs the screen waits on `person.away` before it drives the app. An agent whose work is paused by the daily cost limit is told why, and a workflow can respond to `cost.limit_reached`.

**Why this priority**: These are the global events the person named (`mac.wake`). They are cheap to raise, but they only pay off once waiting and the log exist.

**Independent Test**: Sleep and wake the Mac, lock and unlock it, and reach a cost limit on a scratch setup. Confirm that each appears in the log, labelled "This Mac", and that a waiting agent and a workflow each respond to one of them.

**Acceptance Scenarios**:

1. **Given** the Mac goes to sleep and wakes, **When** it wakes, **Then** `mac.sleep` and `mac.wake` are both recorded. `mac.sleep` is recorded when sleep is announced, and waits and workflows on `mac.wake` respond within seconds of waking.
2. **Given** the person locks the screen or is idle past a threshold, **When** that happens, **Then** `person.away` is recorded. When they unlock or return, `person.back` is recorded.
3. **Given** agents in several projects, **When** a machine event happens, **Then** agents in any project can wait on it and workflows in any project can trigger on it.

---

### Edge Cases

- **Waiting on something that has already happened.** Waiting only looks forward from the point it names, so an agent never wakes on a stale event by accident. An agent that wants the current state asks for recent events, or checks directly, and then waits from that point.
- **Several matching events at once.** The agent wakes once. Its prompt names the first match and says how many more arrived before it resumed. The rest stay in the log.
- **The app restarts, or the Mac restarts, during a wait.** The wait survives and resumes once the app is running again. Events that happened while the app was not running are not invented afterwards. Pull-request and branch changes that were missed are raised when they are next noticed, carrying the time they were noticed.
- **The agent can no longer take a prompt when its event arrives.** For example, its runtime is gone. The wait is dropped, the log says the agent could not be woken, and the agent's chat shows the event it missed.
- **The person prompts a waiting agent.** Their prompt takes the turn, and the wait is cancelled. The agent is told this in the same prompt, so it can wait again if it still needs to.
- **An agent calls wait again while already waiting.** The new wait replaces the old one. An agent has at most one wait at a time, and one wait may name several events.
- **Waiting on another project's events.** This is refused. An agent sees machine events and its own project's events only. Pull-request events belong to the project whose repository the pull request is in.
- **Floods.** An event that happens very often (for example, `branch.moved` during a rebase storm) is still recorded, but repeated identical events within a short window are recorded once with a count, as 008 already does for refusals.
- **The log grows without end.** Events older than the retention period are dropped, oldest first. Consequences are dropped with their event.
- **Unknown event names.** A wait naming an event that is not in the catalogue, and not in the custom namespace, is refused with the list of valid names. A workflow naming one is listed as not yet supported and stays inert, as today (008 FR-013).
- **An older phone or Mac.** A device that doesn't know the events page simply lacks it. A workflow using a new event name reads there as a trigger it does not know, and is inert rather than an error.

## Requirements *(mandatory)*

### Functional Requirements

#### Events

- **FR-001**: An event MUST be a recorded fact with a name, the time it happened, a scope (this Mac, or one project), a plain-language sentence, and a small set of named details (for example, the agent, pull request number, branch, or resource concerned).
- **FR-002**: Event names MUST be lowercase and dotted as `subject.what_happened` (for example, `pull_request.checks_failed`), and MUST be the same names in waits, in workflow files, in the log, and in what agents are told.
- **FR-003**: The app MUST raise at least the events in the catalogue below, in the scope given there.

| Event | Scope | Details |
|-------|-------|---------|
| `agent.started` | project | agent |
| `agent.finished` | project | agent, outcome |
| `agent.asked_permission` | project | agent |
| `agent.asked_form` | project | agent |
| `agent.blocked` | project | agent, what it waits on |
| `agent.stopped` | project | agent; someone or something stopped it |
| `agent.failed` | project | agent, reason; it ended in an error |
| `workflow.ran` | project | workflow, agent |
| `workflow.completed` | project | workflow, agent |
| `workflow.refused` | project | workflow, reason |
| `pull_request.opened` | project | number |
| `pull_request.checks_failed` | project | number |
| `pull_request.checks_passed` | project | number |
| `pull_request.review_comments` | project | number |
| `pull_request.approved` | project | number |
| `pull_request.changes_requested` | project | number |
| `pull_request.conflicts` | project | number |
| `pull_request.merged` | project | number |
| `pull_request.closed` | project | number |
| `pull_request.changed` | project | number, which of the above; raised alongside every pull-request event, as the catch-all |
| `branch.moved` | project | branch, from, to; for the project's default branch and for any branch an agent's worktree is on |
| `lease.granted` | Mac | resource, agent |
| `lease.released` | Mac | resource; released, ended or expired |
| `mac.sleep` / `mac.wake` | Mac | none |
| `person.away` / `person.back` | Mac | why: locked or idle |
| `cost.limit_reached` | Mac or project | which limit |
| `server.offline` / `server.online` | Mac | server; only where servers (037) exist |
| `custom.<name>` | project | publisher, message, details |

- **FR-004**: Events MUST only describe the viewer's own pull requests, in the sense 038 uses. They MUST NOT carry transcript content, file contents or credentials.
- **FR-005**: Things that change continuously (streamed output, usage ticks, window-refresh notifications) MUST NOT be events.

#### Waiting

- **FR-006**: The app MUST give agents a tool to wait on one or more events. Each event is named in full, or by a subject with a wildcard (`pull_request.*`), and each may be narrowed by details (for example, pull request 41, agent X, or custom name `build_green`). A wait may also have a deadline.
- **FR-007**: A wait MUST be one-shot: it ends at its first match, at its deadline, or on cancellation. An agent MUST have at most one wait at a time, and a new wait replaces the old one.
- **FR-008**: The tool MUST hold the request open for up to the same limit a lease request uses (036). If the wait is satisfied within that limit, it MUST return the event. Otherwise it MUST return "still waiting", keep the wait, and tell the agent it may end its turn.
- **FR-009**: When a wait is satisfied, or its deadline passes, after the agent's turn has ended, the app MUST start the agent again with a prompt that names the event (or the timeout), its time and its details, and says how many further matches arrived before the agent resumed.
- **FR-010**: Every event MUST carry a position in the log. The tool MUST let an agent wait from a position it was given earlier, so that nothing that happens between a check and a wait is missed.
- **FR-011**: The app MUST give agents a way to read recent events in their scope (machine and own project), newest first, with positions. The same tool MUST also be able to list the event catalogue.
- **FR-012**: A waiting agent MUST show as Blocked (039) on every device, naming what it waits on and since when. `finish_turn`'s `blocked` on agents MUST be shown in the same way as a wait on `agent.finished` for those agents.
- **FR-013**: A wait MUST end without resuming the agent when the agent cancels it, the person cancels it from the chat, the person prompts the agent, or the agent is stopped or archived. When the person's prompt cancels a wait, the agent MUST be told this in that prompt.
- **FR-014**: Waits MUST survive the app and the Mac restarting. Events MUST NOT be invented for the time the app was not running.
- **FR-015**: An agent MUST NOT be able to wait on events outside its own project, apart from Mac-scoped events.
- **FR-016**: While waiting with its turn ended, an agent MUST cost nothing.

#### Publishing

- **FR-017**: The app MUST give agents a tool to publish an event named `custom.<name>`, with an optional message of up to 500 characters and optional details. The event MUST be scoped to the agent's project and attributed to the agent.
- **FR-018**: Publishing any name outside `custom.` MUST be refused.
- **FR-019**: An agent MUST be limited to 30 publishes an hour. Anything over the limit MUST be refused with the reason.
- **FR-020**: A workflow fire caused by a published event MUST take the chain depth of the publishing agent's run plus one (008 FR-021).

#### Workflows

- **FR-021**: Every event in the catalogue, including `custom.*`, MUST be usable as a workflow trigger, optionally narrowed by details, using the same syntax a wait uses.
- **FR-022**: Today's nine trigger names MUST keep working unchanged, as aliases (`agent-finished` for `agent.finished`, and so on), and MUST NOT be rewritten in the file. `agent-stopped` MUST continue to match both `agent.stopped` and `agent.failed`. `schedule` stays a trigger and is not an event.
- **FR-023**: All the existing workflow rules (chain depth, one run at a time, archiving, ceilings, refusals and the `triggering` mode) MUST apply to every event trigger. `triggering` MUST be refused for an event that has no agent in its details, with that reason.
- **FR-024**: The workflow tool and the wait tool MUST describe the same catalogue in the same words.
- **FR-025**: New trigger names MUST reach older devices in a shape they read as a trigger they do not know, not as a file they cannot read.

#### Seeing events

- **FR-026**: The Mac MUST have an events page listing events newest first, across all projects and the Mac. Each row shows its time, name, sentence, scope and consequences.
- **FR-027**: An event's consequences MUST include every workflow it fired, every workflow that refused it (with the reason), every agent it woke, and every agent that could not be woken. Each MUST lead to its agent or workflow.
- **FR-028**: The events page MUST filter by project and by event subject, and MUST update live.
- **FR-029**: Phone and iPad MUST show the same events and consequences, read-only.
- **FR-030**: A workflow's latest outcome on the project page MUST lead to the event that caused it.
- **FR-031**: Identical events repeated within 60 seconds MUST be recorded once with a count.
- **FR-032**: The log MUST keep at least 7 days of events and at most 10,000, dropping the oldest first.

### Key Entities

- **Event**: A named fact. It has a time, a scope (this Mac or one project), a sentence, details, a position in the log, an optional publisher (for `custom.*`), and a list of consequences.
- **Event kind**: An entry in the catalogue. It has a name, a scope, the details it carries, and one sentence saying what it means. The wait tool, the workflow tool and the events page all read from this one catalogue.
- **Wait**: An agent's single outstanding subscription. It has the events and details it matches, a position to wait from, an optional deadline, and when it began. It ends in one of three ways: matched, timed out, or cancelled (with who cancelled it).
- **Consequence**: What the app did because of an event. It is one of: a workflow fired, a workflow refused (with the reason), an agent woken, or an agent that could not be woken.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent waiting on an app-raised or published event is running again within 10 seconds of the event being recorded.
- **SC-002**: Pull-request events are recorded within one refresh interval of the change being visible on GitHub. `mac.wake` is recorded within 10 seconds of waking.
- **SC-003**: A waiting agent whose turn has ended uses no tokens until its event or deadline.
- **SC-004**: After being away, the person can answer "what happened, and what did the app do about it?" from the events page in under 30 seconds, without opening a chat.
- **SC-005**: No wait is lost across an app restart. In 20 restarts with waits outstanding, every wait is still there afterwards.
- **SC-006**: Every existing workflow file in the repository, and every example the app offers, behaves the same before and after, with no file changed.
- **SC-007**: An agent never needs to poll to wait for any of the conditions in the catalogue.

## Assumptions

- The limit on how long a request can be held open is the one 036 measured (about 45 seconds across Claude, Grok and Cursor). Runtimes that don't get the app's tools, such as Copilot, cannot wait. That is the same gap they already have with leases.
- `person.away` means the screen is locked, or there has been no input for 5 minutes. The threshold is fixed in this version.
- Pull-request events come from the refresh 038 already does. This feature adds no new polling of GitHub, and events arrive only as fast as that refresh notices changes.
- `branch.moved` covers local changes that the app sees (commits, merges, fetches), not pushes to remote branches that nobody fetched.
- The events log belongs to the Mac, like costs and leases. It is not written into the project's repository.
- Scripts, git hooks, CI and webhooks cannot publish events in this version. The `custom.` namespace is chosen so that they can join later without new rules.
- The phone and iPad cannot publish events, cancel waits or filter beyond what the Mac page offers. They read.
