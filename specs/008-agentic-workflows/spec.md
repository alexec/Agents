# Feature Specification: Agentic Workflows

**Feature Branch**: `008-agentic-workflows`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "Agentic Workflows are Open Knowledge Format files within a specific location within the project repo. The front matter describes what event should cause the workflow to run. The body is the prompt to the agent. Create a MCP tool for agents to manage their project's workflows. Show the workflows on the project page. It should be possible for workflows to start new agents, or resume existing ones. I'm not sure about the list of triggers, but at the minimum, a timer on the hour or half hour on certain times of day, when another agent finishes their work or asks a question. Propose other events that the app could trigger on."

## Clarifications

### Session 2026-09-19

- Q: Which set of trigger events should Agentic Workflows support in the first version? → A: In-app lifecycle signals only — timer, agent finished, permission asked, elicitation asked, agent stopped or failed, workflow completed, manual run. File, git and GitHub triggers deferred, but the front matter must leave room for them.
- Q: When a workflow fires, how does it decide which agent runs the prompt? → A: Front matter names one of three modes: `new`, `standing`, `triggering`.
- Q: What stops a workflow from firing on its own output and looping forever? → A: A chain-depth limit, default 3, plus one run in flight per workflow — a second fire skips rather than queues.
- Q: An agent writes a workflow file through the MCP tool. When is that workflow allowed to fire? → A: Writing raises a permission request like any other tool call; once approved the workflow is live. No separate enable step.
- Q: What can you do with workflows on the project page? → A: List with trigger and next fire, Run now, pause. No separate run history — every run starts or resumes an agent, and the agent list already shows those.
- Q: Refused fires produce no agent, so a workflow that keeps skipping looks identical to one that is not triggering. How is that surfaced? → A: The project page must show that a workflow was refused and why.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A workflow runs on a schedule (Priority: P1)

Someone writes a file into their project — a Markdown file with a short block of metadata at the top saying *every half hour between nine and six on weekdays*, and a body that reads like something you would type into the prompt box: *check whether the build is still green, and if it isn't, find out what broke it*. They open the project page. The workflow is listed, with its schedule in plain words and the time it will next run. At half past nine, an agent starts in that project with that prompt, and appears in the agent list like any other.

**Why this priority**: This is the whole idea in its smallest honest form — a prompt that runs itself, kept in the repo next to the code it is about. Nothing in the app does this today; every agent is started by a person typing. Shipping only this story already turns the app from something you drive into something that also runs on its own.

**Independent Test**: Write one workflow file into a project with a schedule a few minutes out. Confirm it appears on the project page with its schedule and next fire time, wait, and confirm an agent starts with that prompt at that time.

**Acceptance Scenarios**:

1. **Given** a project with no workflows, **When** a well-formed workflow file is written into the project's workflow folder, **Then** the project page lists it — its name, its trigger described in plain language, and when it will next run — without the app being restarted.
2. **Given** a listed workflow whose schedule falls due while the app is running, **When** that time arrives, **Then** an agent starts in that project with the workflow's body as its prompt, and the agent list shows it as started by that workflow.
3. **Given** a listed workflow, **When** the reader taps Run now, **Then** it runs immediately regardless of its schedule, and its next scheduled fire is unaffected.
4. **Given** a workflow in `standing` mode that has run before, **When** it fires again, **Then** the prompt goes to the same agent as last time, continuing that conversation rather than starting a fresh one.
5. **Given** a running or scheduled workflow, **When** the reader pauses it, **Then** it stops firing, its row says so, and the workflow file on disk is unchanged.
6. **Given** several workflows in a project, **When** the reader pauses the project's workflows as a whole, **Then** none of them fire until that is lifted.

---

### User Story 2 - A workflow reacts to what an agent just did (Priority: P2)

An agent finishes a long piece of work. A workflow fires on that, and a second agent picks up where it left off — reviewing the diff, or running the tests, or writing the commit message. Another workflow watches for agents asking permission and answers the routine ones. Another notices an agent that stopped without finishing, and looks at why. The prompts are in the repo, so the project's habits travel with it.

**Why this priority**: The schedule is useful, but reacting to agents is what makes this an *agentic* workflow rather than a cron job. It is second because it depends on the whole of story 1 — a workflow that cannot be listed, paused, or run by hand is not safe to hook to something that fires as often as an agent finishing.

**Independent Test**: Write a workflow triggered on an agent finishing. Start an agent by hand, let it finish, and confirm the workflow's agent starts with the triggering agent's identity available to it.

**Acceptance Scenarios**:

1. **Given** a workflow triggered on an agent finishing, **When** any agent in that project ends a turn having completed its work, **Then** the workflow fires and its prompt names which agent finished.
2. **Given** a workflow triggered on an agent asking for permission, **When** an agent in that project raises a permission request, **Then** the workflow fires while that request is still outstanding.
3. **Given** a workflow in `triggering` mode fired by an agent's event, **When** it runs, **Then** the prompt is sent to that same agent, continuing its conversation, rather than to a new one.
4. **Given** a workflow in `triggering` mode whose triggering agent can no longer take a prompt, **When** it fires, **Then** no agent is started and the refusal is recorded with that reason.
5. **Given** workflow A triggered on a schedule and workflow B triggered on workflow A completing, **When** A's run finishes, **Then** B fires.

---

### User Story 3 - You can see that a workflow did not run, and why (Priority: P3)

A workflow that fires produces an agent, and the agent list makes that obvious. A workflow that is refused produces nothing at all — and a workflow silently skipping every fire looks exactly like a workflow whose trigger never matched. The project page has to tell the two apart. The row says what happened last: *ran, twenty minutes ago*, or *did not run — a previous run is still going*, or *did not run — this chain is three deep*.

**Why this priority**: Every safety rule in this feature works by refusing to run, so every safety rule is a way for the feature to fail quietly. Without this, the first thing anyone does when a workflow seems dead is edit the file that was never the problem. It follows story 2 because the refusals worth seeing — chain depth, a run still in flight — only become reachable once workflows can trigger each other.

**Independent Test**: Write a workflow whose prompt takes a long time, on a schedule tight enough that a second fire falls due while the first is still running. Confirm the project page says the second fire was refused because a run was still in flight, and that no second agent was started.

**Acceptance Scenarios**:

1. **Given** a workflow whose previous run has not finished, **When** its trigger fires again, **Then** no agent is started and its row says the fire was refused because a run is still in flight.
2. **Given** a chain of workflows that have triggered each other to the depth limit, **When** the next one would fire, **Then** it is refused, its row says the chain limit was reached, and the chain stops without the reader doing anything.
3. **Given** a workflow file whose metadata block cannot be read, **When** the project page lists it, **Then** it appears with the problem stated plainly and never fires.
4. **Given** a workflow whose trigger names an event this version does not support, **When** the project page lists it, **Then** it appears as not yet supported and never fires, rather than being hidden or treated as an error in the file.
5. **Given** a workflow that has been refused for the same reason several times in a row, **When** the reader looks at its row, **Then** the reason is stated once with a count, rather than as a list of identical entries.
6. **Given** a workflow whose scheduled time passed while the app was not running, **When** the app next opens, **Then** the missed fire is not replayed, and the row says the fire was missed.

---

### User Story 4 - An agent sets up its own workflows (Priority: P4)

Someone tells an agent *every morning, check whether any of our dependencies have security advisories, and open an agent on it if they do*. The agent writes the workflow file itself. Writing it raises a permission request that says, in plain words, what will run and when — not *write file* but *run every weekday at 9am, in a new agent*. The person approves, and it is live. Later they ask the agent to list what workflows the project has, or to change one, or to remove one it no longer needs.

**Why this priority**: The most valuable part and the last one needed. Everything before it works with a file written by hand; this removes the need to know the file format at all. It is last because the permission prompt it depends on only has something meaningful to say once triggers and modes are settled.

**Independent Test**: Ask an agent to create a workflow. Confirm a permission request describes the trigger and the mode in plain words, and that approving it makes the workflow appear on the project page.

**Acceptance Scenarios**:

1. **Given** an agent working in a project, **When** it asks the app to list that project's workflows, **Then** it receives each workflow's name, trigger, agent mode and prompt, with no permission request raised.
2. **Given** an agent working in a project, **When** it creates or changes a workflow, **Then** a permission request is raised that states the trigger and the agent mode in plain language, and the change is written only if it is approved.
3. **Given** a permission request for a workflow change, **When** the reader declines it, **Then** nothing is written, no workflow is created or altered, and the agent is told it was declined.
4. **Given** an agent working in a project, **When** it attempts to write a workflow outside that project's workflow folder, **Then** the attempt is refused.
5. **Given** an agent that has created a workflow, **When** it asks to remove it, **Then** removal is subject to the same permission request as creation.

---

### Edge Cases

- **The app was closed when a schedule fell due.** Every missed fire is skipped rather than replayed, or opening the app after a weekend starts a queue of agents nobody asked for. The skip must be visible without a fortnight of identical rows.
- **Two fires at once.** A workflow triggered on both a schedule and an agent finishing, where both land in the same moment. One run, not two.
- **A `standing` agent that was archived, or stopped, or whose runtime is gone.** The workflow's own long-lived agent is an ordinary agent that the reader can archive like any other. The next fire has to either pick it up again or say plainly that it could not.
- **The workflow file is deleted or renamed while its run is in flight.** The run finishes; the workflow leaves the list. A `standing` agent it left behind stays in the agent list as an ordinary agent.
- **A renamed file.** Identity comes from the file name, so renaming a workflow is indistinguishable from deleting one and creating another: pause state and the `standing` agent do not follow it.
- **A trigger this version does not understand**, because the file was written by a newer version or by hand. It must be listed and inert, not an error and not hidden — this is how the format leaves room for triggers that come later.
- **A prompt body that is empty**, or a file with metadata and nothing under it.
- **A workflow whose own agent triggers it.** An agent started by a workflow finishes, which is exactly what the `agent finished` trigger watches for. The chain depth is what stops this, and the first refusal must say so clearly enough that the reader understands the workflow is looping.
- **Run now during a run.** The same in-flight rule applies to a fire the reader asked for by hand, and being told why is more important here than anywhere else, because someone is watching.
- **The project folder has gone** — moved, unmounted, deleted — while workflows are scheduled.
- **A great many workflows**, or one that fires every half hour all day, filling the agent list.
- **A workflow in a project that is not currently open.** Workflows belong to the project, not to what is on screen.

## Requirements *(mandatory)*

### Functional Requirements

**The workflow file**

- **FR-001**: A workflow MUST be a single plain-text file in the project's repository, opening with a metadata block and followed by a body, so that workflows are versioned, reviewed and shared with the code they act on.
- **FR-002**: The system MUST read workflows from one known folder within the project, and MUST NOT treat files elsewhere in the project as workflows.
- **FR-003**: A workflow's body MUST be used verbatim as the prompt sent to the agent.
- **FR-004**: A workflow MUST be identified by its file name, and that identity MUST be what the system uses to remember which agent is a workflow's standing agent and whether it is paused.
- **FR-005**: The metadata block MUST carry the workflow's trigger or triggers and its agent mode, and MUST tolerate keys it does not recognise rather than rejecting the file.
- **FR-006**: A workflow whose metadata block cannot be read MUST be listed with the problem stated, and MUST NOT fire.
- **FR-007**: Workflows MUST be picked up when they are added, changed or removed on disk, without the app being restarted.

**Triggers**

- **FR-008**: The system MUST support a schedule trigger that fires on the hour or the half hour, constrained to a range of times of day and a set of days of the week.
- **FR-009**: The system MUST support triggers on these events, for any agent in the same project: an agent finished its work; an agent asked for permission; an agent raised a form to be filled in; an agent stopped or failed without finishing.
- **FR-010**: The system MUST support a trigger on another workflow's run completing, so that workflows can be chained deliberately.
- **FR-011**: A workflow MUST be able to declare more than one trigger, and MUST run once per firing event rather than once per matching trigger.
- **FR-012**: Every workflow MUST be runnable on demand from the project page, whatever its triggers, and this MUST be available even for a workflow that is paused or has no trigger the system understands.
- **FR-013**: A trigger named in a workflow that this version does not support MUST cause the workflow to be listed as not yet supported and to stay inert, rather than being rejected as malformed.
- **FR-014**: A scheduled fire that falls due while the app is not running MUST NOT be replayed when the app next opens.

**Which agent runs the prompt**

- **FR-015**: A workflow MUST declare one of three agent modes: `new`, starting a fresh agent on every fire; `standing`, resuming one long-lived agent belonging to that workflow so it accumulates context across fires; `triggering`, resuming the agent whose event caused the fire.
- **FR-016**: A `standing` workflow whose agent no longer exists or can no longer take a prompt MUST start a fresh agent and adopt it as the new standing agent.
- **FR-017**: A `triggering` workflow whose agent can no longer take a prompt MUST NOT start a substitute, and MUST record the refusal with that reason.
- **FR-018**: A `triggering` workflow fired by a schedule or by a manual run — where there is no triggering agent — MUST be refused with that reason.
- **FR-019**: An agent started or resumed by a workflow MUST be identifiable as such in the agent list, naming the workflow responsible.
- **FR-020**: When a workflow fires on an agent event, the run MUST make the triggering agent's identity and what it did available to the prompt, so that a `new` agent has enough to act on.

**Refusing to run**

- **FR-021**: Every run MUST carry a chain depth: a fire caused by a schedule, by a manual run, or by an agent the system did not start counts as depth zero, and a fire caused by an agent or a workflow run that a workflow itself produced counts as one deeper than that.
- **FR-022**: A fire beyond the chain-depth limit MUST be refused. The limit MUST default to three.
- **FR-023**: A workflow whose previous run is still in flight MUST refuse a new fire rather than queueing it or running it alongside.
- **FR-024**: The reader MUST be able to pause an individual workflow and to pause all of a project's workflows, and pausing MUST NOT modify the workflow file.
- **FR-025**: A paused workflow MUST refuse every fire, including one asked for by hand, and MUST say that pausing is the reason.
- **FR-026**: Every refused fire MUST be recorded with its reason. The reasons MUST include at least: the chain-depth limit was reached; a run is still in flight; the workflow is paused; the metadata could not be read; the trigger is not supported; the agent to resume was unavailable; the scheduled time was missed while the app was not running; the project folder is unavailable.

**The project page**

- **FR-027**: The project page MUST list the project's workflows, each with its name, its trigger described in plain language rather than as the raw metadata, and — where it has a schedule — the time it will next run.
- **FR-028**: Each workflow's row MUST show the outcome of its most recent fire: either that it ran, with when, or that it was refused, with when and why.
- **FR-029**: A row showing a run MUST lead to the agent that run started or resumed.
- **FR-030**: Consecutive refusals for the same reason MUST be shown as that reason once with a count, not as repeated entries.
- **FR-031**: Each row MUST offer Run now and pause, and the project's list MUST offer pausing every workflow at once.
- **FR-032**: The project page MUST NOT offer editing a workflow's trigger or body; authoring happens in the file or through an agent.

**The tool agents use**

- **FR-033**: The app MUST serve agents a tool for listing, reading, creating, changing and removing the workflows of the project they are working in.
- **FR-034**: Listing and reading workflows MUST NOT require the reader's approval.
- **FR-035**: Creating, changing or removing a workflow MUST raise a permission request, and MUST take effect only if it is approved.
- **FR-036**: That permission request MUST state, in plain language, what would cause the workflow to run and which agent would run it — not merely that a file would be written.
- **FR-037**: The tool MUST refuse to read or write anything outside the workflow folder of the project the agent is working in.
- **FR-038**: A workflow created through the tool MUST need no further step to become live once its permission request is approved.

### Key Entities

- **Workflow**: A file in the project's workflow folder. Identified by its file name. Carries its triggers, its agent mode, and the prompt body. Everything about what it does lives in the file and travels with the repository.
- **Trigger**: What causes a workflow to fire — a schedule, or something an agent or another workflow did. A workflow may have several. Triggers this version does not understand are held, not discarded.
- **Agent mode**: Which agent receives the prompt — a fresh one, the workflow's own long-lived one, or the one whose event fired it.
- **Run**: One firing of one workflow. Carries the workflow it belongs to, what triggered it, its chain depth, the agent it started or resumed, and when it finished. A run in flight is what blocks a second one.
- **Refusal**: A fire that produced no run, with its reason and when it happened. The counterpart to a run, and the only evidence a workflow leaves when it declines to act.
- **Chain depth**: How far a run is from something a person or a clock did. Zero for a schedule, a manual run, or an agent nobody automated; one more for each workflow-caused step after that.
- **Workflow state**: What the app remembers about a workflow that does not belong in the file — whether it is paused, which agent is its standing agent, and the outcome of its last fire. Keyed by the workflow's file name, kept out of the repository.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A workflow file added to a project appears on that project's page within five seconds, with no restart and no further action.
- **SC-002**: A workflow's row answers *when will this run* and *what happened last time* without the reader opening anything else.
- **SC-003**: No fire is ever silent: every fire either produces an agent reachable from the workflow's row, or a stated reason on that row. In testing, zero fires leave no trace.
- **SC-004**: A pair of workflows that trigger each other comes to rest within four runs, with no action from the reader, and the row of the one that stopped says why.
- **SC-005**: Stopping a workflow that is behaving badly takes one action on the project page and no edit to any file.
- **SC-006**: Someone who has never seen the file format can have a working scheduled workflow in their project by asking an agent for it and approving one request.
- **SC-007**: A permission request for a workflow change can be judged without opening the file: it states the trigger and the agent mode in words the reader already understands.
- **SC-008**: Scheduled fires land within one minute of their stated time whenever the app is running.
- **SC-009**: A project with twenty workflows lists and scrolls as smoothly as the agent list beneath it.

## Assumptions

- Workflows live in `.agents/workflows/` within the project, one Markdown file per workflow, each opening with a YAML metadata block. This is what "Open Knowledge Format" is taken to mean here: an ordinary Markdown document with front matter, the same shape the app already understands elsewhere. The folder is new; `.specify/workflows/` already exists for a different purpose and is deliberately left alone.
- A workflow's name, as shown on the project page, is derived from its file name unless the metadata block gives one.
- Lifecycle triggers fire for any agent in the same project. Filtering by which agent, which runtime, or what it was working on is a later decision, not a gap in this one.
- The schedule's granularity is the hour and the half hour, as asked. Finer schedules were considered and left out: they invite workflows that fire faster than anyone can read the results.
- Schedules are interpreted in the machine's local time zone and follow it when it changes.
- The chain-depth limit is a fixed default of three. Making it settable per workflow or per project is deferred until there is a case for it; the limit exists to stop runaways, and a runaway workflow that can raise its own limit is not stopped.
- Pause state and the identity of a workflow's standing agent are held by the app, not written back into the file. Writing them to disk would raise a permission request every time and fill the repository's history with state nobody wants to review.
- Refusals are surfaced on the project page only. Notifying the reader elsewhere when a workflow keeps refusing is out of scope for this version.
- Only the most recent outcome per workflow is kept. A full run history was considered and deliberately left out, because every run that actually happens is already an agent in the agent list.
- Workflows are the project's, not the open window's: a project's workflows fire whether or not that project is on screen, provided the app is running.
- The app must be running for any workflow to fire. Running workflows while the app is closed is out of scope and would require capabilities the daemon does not have today.
- The tool agents use is served by the app in the same way its existing tools are, and is scoped to the project the calling agent is working in.
- File, git and external service triggers are out of scope for this version, but the metadata block is designed so that adding them later changes no existing file.
- The feature is macOS-only, matching the app.
- The project constitution is currently an unfilled template, so no project-specific principles constrain this specification.
