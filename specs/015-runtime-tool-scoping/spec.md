# Feature Specification: Our Tools, Not Theirs

**Feature Branch**: `015-runtime-tool-scoping`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "For each of the agents, start the app and list what tools that they have, then determine if some of those tools conflict with this app's remit, such as managing workflows and performing escalations and storing artefacts. Then figure out a way to disable those tools so the agent will use our tools and not those tools."

## Why this feature exists

This app hands every agent three tools of its own and leans on a fourth that belongs to the runtime.
`suggest_next_prompts` is how a turn ends. `show_file` is how a file is put in front of the person.
`manage_workflows` is how a standing arrangement comes to exist. And the question an agent asks when
something is the person's to decide goes out as an elicitation, which the daemon holds, which
survives the window being shut, and which reaches a phone. Four things the app owns, because in each
case the app is the only thing that can carry them to the person.

Every runtime arrives already holding its own version of all four.

Claude brings `Workflow`, `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup`, `Monitor`,
`RemoteTrigger`, `PushNotification`, `ReportFindings`, `DesignSync`, `Agent`, `ListAgents`,
`SendMessage`, `TaskOutput`, `TaskStop`, and, through the person's own connectors, a document store
and a Drive it can write to. Grok brings `workflow`, `scheduler_create`, `scheduler_delete`,
`scheduler_list`, `monitor`, `spawn_subagent` and its kin. Copilot brings `task`, `session_store_sql`,
a set of agent tools, and — through an MCP server the person already runs — `escalation_raise`,
`escalation_await`, `prompt_suggest`, `output_list` and a task queue, which is to say a second, older
copy of this app's whole remit. Cursor brings `CreateGoal`, `UpdateGoal` and `Task`.

None of that is hypothetical. Ask any of them for something to happen every morning and the obliging
answer is a cron entry, a scheduler row or a goal — written somewhere the app cannot show, cannot
edit, cannot delete, and cannot tell the person about. The workflow row never appears. Ask Copilot
something it cannot decide and the question can go into another queue entirely: not held by the
daemon, not on the phone, not waiting anywhere the person is looking. Ask for a report and it can
land in a document the app has never heard of instead of the conversation the person is reading.
Each of these is the same failure wearing different clothes: work the app is meant to carry ends up
somewhere the app cannot see, and the person is the one who finds out later, or never.

The app has been fighting this with words. The briefing already spends a paragraph telling agents not
to write crontabs. Words are what you use when you have nothing else, and they lose: an instruction
sits in the first prompt of a conversation, and a tool sits in front of the model on every single
turn. The fix is to stop asking an agent to ignore a tool and to take the tool away — for the
sessions this app starts, and only for those.

That last clause is half the feature. The person's own Claude Code, their own Copilot, their own Grok
keep everything they have. Nothing here edits a config file in their home directory, and nothing here
is left behind when the app is not running. An agent started by this app is scoped to what this app
can account for; the same runtime started from their terminal a minute later is untouched.

**This feature does not add a tool and does not change one.** It decides which of the tools an agent
already has it gets to keep.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The morning check that lands in the app (Priority: P1)

Someone tells an agent: *check the build every weekday at nine and tell me if it is red.* Today the
answer depends entirely on which runtime is answering. Claude writes a cron entry. Grok makes a
scheduler row. Cursor sets a goal. In none of those cases does a workflow appear in the project, and
in none of them can the person see, edit or remove the thing they just asked for — the app's
workflows list is empty and the arrangement lives somewhere else, if it lives at all.

After this feature, the tool that would have done that is not there. The only way to make something
happen on its own is `manage_workflows`, so the agent uses it, the person is asked to confirm the
new workflow in plain words, and the arrangement shows up in the project as a row they own.

**Why this priority**: Standing arrangements are the clearest loss. They are invisible when they go
wrong, they outlive the conversation that made them, and they are the case the briefing already
tries and fails to prevent.

**Independent Test**: Ask each of the four runtimes, in a fresh conversation, for a recurring check.
Confirm a workflow appears in the project for each one, and that no cron entry, scheduler row or
runtime-side goal was created.

**Acceptance Scenarios**:

1. **Given** an agent on any runtime, **When** the person asks for something to happen on a
   schedule, **Then** the agent has no scheduling tool of its own available, and the arrangement is
   made through the app's workflow tool or not at all.
2. **Given** an agent that tries to reach a tool that has been taken away, **When** it makes the
   call, **Then** it is told plainly that the tool is not available here and which app tool does
   that job, rather than failing silently or ending the turn.
3. **Given** the same runtime started by the person outside the app, **When** they use it, **Then**
   every tool it normally has is still there.

---

### User Story 2 - A question that reaches the phone (Priority: P1)

An agent hits something only the person can decide: which of two credentials, whether to drop the
index first, is this the account to bill. The app's answer to that is an elicitation the daemon
holds — it waits, it survives the window closing, it appears on the phone. An agent that instead
raises the question into its own escalation queue, or sends it as a notification of its own, has
answered nobody: the app never sees it, the phone never rings, and the turn ends with a question
buried in a reply the person may not read.

After this feature the rival escalation routes are gone and the runtime's own question tool — the
one the app turns into an elicitation — is deliberately kept. Asking the person is still easy. There
is just one way to do it, and it is the way that reaches them.

**Why this priority**: An escalation that goes to the wrong place is worse than no escalation: the
agent believes it asked, and the person is never asked. It is also the one case where the fix is
partly *not* removing something, which makes it easy to get wrong.

**Independent Test**: Give an agent on each runtime a task that cannot be finished without a
decision. Confirm the question arrives as a held elicitation, visible in the app and on the phone,
and that no question was filed into any other queue.

**Acceptance Scenarios**:

1. **Given** an agent with a decision it cannot make, **When** it asks, **Then** the question
   arrives through the app's escalation path and waits there for an answer.
2. **Given** a runtime whose question tool is the app's escalation path, **When** tools are scoped,
   **Then** that tool is still available and still works.
3. **Given** a runtime that carries a second escalation or notification channel of its own, **When**
   tools are scoped, **Then** that channel is not available to the agent.

---

### User Story 3 - One row of suggestions, from one place (Priority: P2)

The chips above the prompt come from `suggest_next_prompts`. One runtime ships a follow-up tool of
its own, and when an agent calls that instead, the app's row stays empty: the suggestions exist, and
the person never sees them.

After this feature there is one tool for it, so the turn ends the way every other turn ends.

**Why this priority**: Visible on every single turn, and cheap — but it is a missing nicety rather
than lost work, so it comes after the two that lose things.

**Independent Test**: End a turn on each runtime and confirm the chips appear, with nothing sent to a
rival suggestion tool.

**Acceptance Scenarios**:

1. **Given** a runtime with a suggestion tool of its own, **When** tools are scoped, **Then** only
   the app's tool is available and the chips appear above the prompt.
2. **Given** any runtime, **When** scoping is applied, **Then** the app's own three tools are
   present and callable, and the number of turns that end with chips does not fall.

---

### User Story 4 - The work stays where the person is reading (Priority: P2)

An agent asked for findings writes them into a document store, a spreadsheet, a Drive file or a
session database — places the app has never heard of. The person is looking at a conversation and a
files pane; the answer is somewhere else, and only the agent knows where.

After this feature the artefact stores that belong to other systems are not offered. What an agent
produces goes into the conversation, into the project's files, or in front of the person with
`show_file`.

**Why this priority**: It costs work rather than losing it — the person can usually still find the
document — but it splits the record of a project across places nobody agreed on.

**Independent Test**: Ask an agent on each runtime for a written summary of what it found. Confirm
it arrives in the conversation or as a file in the project, and that no external document was
created.

**Acceptance Scenarios**:

1. **Given** an agent with tools that write to a store outside the project, **When** tools are
   scoped, **Then** those tools are not available.
2. **Given** an agent asked to produce something written, **When** it answers, **Then** the result is
   in the conversation or in the project's own files.

---

### User Story 5 - A runtime that grew a tool overnight (Priority: P3)

Runtimes update themselves. A tool that did not exist last week exists this week, and a name that
was right last week is spelled differently now. Scoping that is written once and never re-checked
quietly stops covering what it claimed to cover, and the first sign is an agent doing something the
app cannot see.

After this feature there is a way to ask every runtime what it has today and be told which of those
tools the app does not account for — the same idea as the handshake check that already exists for
capabilities, and readable in one screen.

**Why this priority**: It protects the other four stories over time rather than delivering anything
on the day. It is also small.

**Independent Test**: Run the check against all four runtimes. Confirm it lists, per runtime, the
tools that are taken away, the conflicting tools that could not be taken away, and anything new that
is neither.

**Acceptance Scenarios**:

1. **Given** the check is run, **When** a runtime offers a tool the app neither removes nor has a
   written reason to allow, **Then** it is reported as unaccounted for.
2. **Given** a tool name that a runtime no longer recognises, **When** a session is started,
   **Then** the session still starts and the stale name is reported rather than silently ignored.

---

### Edge Cases

- **A runtime with no way to remove a tool.** One of the four has no mechanism at all. The app must
  not pretend otherwise: what cannot be removed is said in words to the agent instead, and written
  down as residue rather than left as a silent gap.
- **Taking away too much.** An agent stripped of the tools it needs to read, edit or run anything is
  not scoped, it is broken. Scoping must never touch file, search, terminal, plan or to-do tools.
- **The escalation tool.** The one tool that looks like a rival and is not. Removing it would take
  away the very thing this feature exists to protect.
- **A name that no longer exists.** Runtimes rename and retire tools. A stale entry must not fail a
  session or stop the other removals from applying.
- **A conversation picked back up.** Scoping applied only when a conversation is first made would
  quietly lapse on resume, load or fork — the same agent, a wider set of tools, no sign of it.
- **The person asking for the thing directly.** "Use Claude Docs for this" cannot be honoured by an
  agent that no longer has it. The agent must say so plainly and offer what the app does have,
  rather than pretending it failed for another reason.
- **A runtime the app cannot scope at all.** A new runtime with no lever must still be usable; it
  simply carries more residue, and the residue is visible.

## Requirements *(mandatory)*

### Functional Requirements

**What is out of bounds**

- **FR-001**: For every runtime the app starts, the tools available to an agent MUST exclude the
  runtime's own means of making something happen on its own: schedules, cron entries, timers,
  wake-ups, monitors, standing goals and workflow tools.
- **FR-002**: They MUST exclude the runtime's own means of raising a question, a form or a
  notification to a person outside the app's escalation path.
- **FR-003**: They MUST exclude the runtime's own means of creating, starting, messaging, inspecting
  or stopping other agents. This app owns what agents exist.
- **FR-004**: They MUST exclude the runtime's own means of storing work outside the project: document
  stores, drives, findings reports and session databases.
- **FR-005**: They MUST exclude any tool that offers the person a follow-up prompt other than the
  app's own.
- **FR-006**: An MCP server attached to a runtime that duplicates the app's remit MUST be excluded
  whole, rather than tool by tool, where the runtime allows it.

**What must survive**

- **FR-007**: The tool the app relies on for escalation — the runtime's question or form tool, the
  one that becomes an elicitation — MUST remain available on every runtime that has one.
- **FR-008**: Reading, searching, editing, writing, running commands, planning and keeping a to-do
  list MUST remain available. Scoping MUST NOT reduce what an agent can do to the work itself.
- **FR-009**: The app's own served tools MUST remain available and MUST be unaffected by scoping.
- **FR-010**: A tool that is merely unrelated to the app's remit, and does not duplicate it, MUST be
  left alone.

**How it is done**

- **FR-011**: Scoping MUST apply only to agents this app starts. It MUST NOT write to, or otherwise
  change, any configuration belonging to the person or to the runtime, and MUST leave nothing behind
  when the app is not running.
- **FR-012**: Scoping MUST be applied every time a conversation is made, picked back up, loaded or
  branched, so a resumed agent is scoped exactly as a new one is.
- **FR-013**: Scoping MUST be decided by what a runtime offers as a means of doing it, in the manner
  of the rest of this app: a runtime that supports a lever gets it, one that does not, does not. No
  behaviour may depend on which runtime it is beyond the policy itself.
- **FR-014**: A name in the policy that a runtime does not recognise MUST NOT fail the session, and
  MUST NOT prevent the remaining removals from applying. It MUST be recorded where somebody will see
  it.
- **FR-015**: An agent that calls a tool that has been taken away MUST be told, in a sentence it can
  act on, that the tool is not available in this app and which of the app's tools does that job.
- **FR-016**: Where a conflicting tool cannot be removed on a given runtime, the agent MUST be told
  in words not to use it, and told what to use instead. Words are the fallback, not the first line.
- **FR-017**: What each runtime is scoped to MUST be written in one place, as a policy that can be
  read and changed without reading the code that applies it.

**Knowing it still holds**

- **FR-018**: There MUST be a way to ask every runtime what tools it has today and report, per
  runtime, which are removed, which conflict and could not be removed, and which are new and
  unaccounted for.
- **FR-019**: The residue — every conflicting tool that could not be removed, and why — MUST be
  written down in the feature's own documents, not discovered by running the app.

### Key Entities

- **Remit category**: One of the jobs this app owns — standing arrangements, escalation, agent
  management, artefacts, suggested prompts. Every removal belongs to exactly one, which is what
  makes the policy arguable rather than arbitrary.
- **Tool policy**: Per runtime, the tools removed, the tools deliberately kept, the mechanism used,
  and the residue that words have to cover. One entry per runtime the app knows how to start.
- **Residue**: A conflicting tool a runtime will not let the app remove. Named, categorised, and
  covered by a line in the briefing.
- **Tool inventory**: What a runtime actually offers today, as answered by the runtime itself, and
  the thing the policy is checked against.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For all four runtimes, asking for something to happen on a schedule produces a workflow
  in the app, and produces no cron entry, scheduler row or runtime-side goal — four out of four,
  where today it is none out of four.
- **SC-002**: For every runtime that can ask a question, a decision the agent cannot make arrives as
  a question held by the app and readable on the phone, and no question is filed anywhere else.
- **SC-003**: The share of turns that end with suggestion chips does not fall for any runtime, and
  rises for the runtime that today answers with a suggestion tool of its own.
- **SC-004**: Nothing the person owns changes: after a day of using the app, their own runtimes,
  started from their own terminal, still have every tool they had before, and no file outside the
  app's own storage has been written.
- **SC-005**: A person can read, in one page, exactly which tools each runtime loses, which it keeps,
  and which conflicting tools it keeps despite the policy — with zero conflicting tools left
  unexplained.
- **SC-006**: Agents still do the work: no increase in turns that end short because a tool the agent
  needed was missing.
- **SC-007**: A runtime updating and changing its tools is caught by running one check, rather than
  by an agent doing something the app cannot see.

## Assumptions

- The four runtimes the app knows how to start are the scope: Claude, Grok, Copilot and Cursor. A
  fifth would need its own entry in the policy, and would carry residue until it got one.
- Three of the four offer a usable mechanism, confirmed against the versions installed on this Mac
  on 2026-09-19 — Claude's ACP adapter 0.78.0, Copilot 1.0.87-0, and Grok's stdio agent. Cursor
  (2026.09.10) offers no way to remove a built-in tool, so its conflicts — a goal tool and a subagent
  tool — are residue covered by words.
- Grok is partial: its own profile mechanism removes the scheduler and subagent tools, and leaves a
  workflow tool and a monitor behind as residue.
- The block is absolute for agents this app starts. A person who genuinely wants their document store
  or their own escalation queue in a particular project is not served by this feature; a per-project
  exception is a later question, and is out of scope here.
- The person's other MCP server that duplicates this app's remit is theirs, is running, and stays
  running. Nothing here stops it; the app simply does not attach it to the agents it starts.
- Removing a tool is stronger than asking an agent not to use it, and the briefing keeps only the
  lines that removal cannot replace. The briefing does not grow as a result of this feature — where a
  tool goes away, the words about it can go too.
- The app's existing permission and folder rules are unchanged. This feature decides what is offered,
  not what is allowed once offered.

## Out of scope

- **Per-project or per-agent exceptions.** One policy per runtime, for now.
- **A settings screen for tools.** The policy is written down, not configured in the window.
- **Anything about the person's own configuration.** The app reads what a runtime offers; it never
  edits what the person has set up.
- **The rival MCP server itself.** Not attached, not disabled, not managed.
- **Scoping what a tool may do once it is offered.** Path rules, permissions and folder scope already
  exist and are not touched here.
- **New app tools.** If a removal leaves a genuine gap — something the person wants and the app
  cannot carry — that is a feature of its own.
