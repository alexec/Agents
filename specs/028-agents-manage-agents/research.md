# Research: An Agent Can Run a Few Agents of Its Own

Every decision below was checked against the code on main at `7e3e540`.

## R1. Where the tools live

**Decision**: Add four tools to the MCP server the app already gives every agent
(`AppService`, served by `agentsd mcp <token>`): `start_agent`, `stop_agent`, `archive_agent`,
`list_my_agents`. Each one is relayed to a new daemon method, the way `manage_workflows` is
relayed to `agents/manageWorkflows`.

**Rationale**: Every tool the app gives an agent already works this way. The helper decides nothing.
The daemon identifies the caller by its token (`appTokens[token] → agentID`). The token is minted
per session and dropped when the session ends. That token is the whole basis for "only its own"
and "only its project": the caller's project is `agents[caller].cwd`, never an argument.

**Alternatives considered**:
- *One `manage_agents` tool with an `action`, like `manage_workflows`.* Rejected. Start takes a
  prompt and settings while stop and archive take only an id, so one schema would have mostly
  optional fields. Separate tools also let a runtime's permission prompt name what is being
  done ("archive_agent") rather than "manage_agents".
- *Let agents use the daemon socket directly.* This is the gap the spec describes. It has no
  identity check and no limits.

## R2. Withholding the tools from agents that another agent started (FR-008)

**Decision**: When the daemon builds an agent's MCP server entry in `appServer(token:)`, it passes
a flag: `appServer(token:, managesAgents:)` adds `--no-agent-tools` to the helper's args for an agent
whose `startedByAgent` is set. The helper passes this to `AppService`, which leaves the four tools
out of `tools/list`. The daemon also refuses any call whose caller has `startedByAgent` set, so a
helper started with the wrong flag still can't do anything.

The flag is known in both places an MCP server entry is built:
- **New session** (`freshSession`): the start request comes from the new agent-start path, which
  knows the new agent will have a starter. `freshSession` gains a `managesAgents: Bool` parameter,
  true by default.
- **Picked back up** (`connect(_:runtime:for:)`): the agent record is available, so the flag is
  `agent.startedByAgent == nil`.

**Rationale**: FR-008 says the tools are not *offered*, and an agent never looks for a tool it
wasn't shown. The daemon check is what enforces it. The flag only keeps the menu honest.

**Alternatives considered**: have `tools/list` ask the daemon at runtime. Rejected, because it
would add a socket round trip to every `tools/list`, and memory warns against polling the socket.

## R3. The limit of three, under concurrency (FR-005, SC-002)

**Decision**: The count is derived, not stored. It is the number of agents in `agents` whose
`startedByAgent` is set, whose standardised `cwd` matches the project and whose state is not
`.archived`, **plus** the number of starts reserved for that project but not yet finished. A start
takes its reservation in the actor before its first `await` and gives it back when it succeeds
(the agent now counts itself) or fails.

**Rationale**: `DaemonCore` is an actor, so everything before the first `await` runs without
interruption. Creating a session awaits a runtime handshake that can take seconds. Without a
reservation, two starts could both see two places in use and both proceed. Deriving the count from
agent records means nothing extra has to be persisted, and a restart recomputes it correctly
(spec edge case "The daemon restarts"). Reservations exist only while a start is running and don't
need to survive a restart, because the start doesn't either.

**Alternatives considered**: a persisted counter. Rejected: it would duplicate what the agent
records already say, and any path that changes an agent's state without updating the counter
would make it drift.

## R4. Starting: runtime, model, permission mode (FR-003)

**Decision**: Reuse the workflow start path. `startAgent(for:run:prompt:)` and `settled(...)` in
`DaemonCore+Workflows.swift` already turn `runtime` / `model` / `permission-mode` into a
`StartRequest`. If there are no settings, no draft is made. With settings, the draft is checked
against the runtime's advertised options, and a value the runtime doesn't offer is refused with
`SettingRefused`, naming what it does offer. Pull the settings-to-request part out into a function
that takes a `WorkflowSettings` and a folder, rather than a `Workflow`. Workflows and this feature
both call it.

**Rationale**: FR-003 says these values mean what they mean in a workflow. Sharing one path keeps
the two in step, including the rule that an unknown value refuses rather than falling back.

## R5. Saying who stopped or archived it (FR-007)

**Decision**: Add events to the state table rather than reuse the person's:
- `AgentEvent.stoppedByAgent` with the same transitions as `.stoppedByUser`, ending
  `EndedReason.stoppedByAgent` ("Stopped by the agent that started it").
- `AgentEvent.archivedByAgent` with the same transitions as `.archivedByUser`, archive reason
  `Agent.ArchivedReason.byAgent`.
- `DaemonCore.stop` and `archive` gain a `by: StopCause` parameter (`.person` or
  `.agent(UUID)`), `.person` by default. Every existing caller is unchanged. Everything else in
  `stop` (withdrawing a pick-up, cancelling open questions, releasing the runtime, the notes about
  queued prompts) is shared.
- A runtime note naming the starter is recorded before the move:
  "‹starter title› stopped this agent." / "‹starter title› archived this agent."

**Rationale**: Reusing `.stoppedByUser` would show "Stopped by you" on the row for something the
person didn't do. This app has repeatedly refused to show endings that aren't true. Older builds
already decode an unknown `EndedReason` as `.unrecognised` and an unknown `ArchivedReason` as
`.byUser`, so a phone on an older build still reads the record.

**Alternatives considered**: a transcript note only, keeping the "Stopped by you" ending. Rejected,
because the row would say something false.

## R6. How the person sees who started it (FR-004, SC-005)

**Decision**:
- `Agent.startedByAgent: UUID?`, persisted, decoded if present (the same shape as
  `startedByWorkflow`).
- **Mac row** (`AgentRow`): a mark beside the title like the workflow mark
  (`person.2`), with the tooltip and accessibility label "Started by ‹starter title›".
- **Phone card** (`Remote/Sources/Projects/AgentCard.swift`): the same mark and label.
- **Chat**: a runtime note is recorded as the new agent's first entry: "Started by ‹starter
  title›." The note is part of the transcript, so it appears at the top of the chat on both
  platforms without any view changes.
- The starter's title is read live. If the starter has since been deleted, the label says
  "another agent".

## R7. Chains and workflows

**Decision**: A helper's lifecycle events fire the project's workflows, like any agent's. For
chain depth, `workflowChainDepth(causedBy:)` falls back to the starter's depth when the helper
has no run of its own. That way a workflow → agent → helper → workflow loop still counts against
the existing chain limit. A workflow's agent (`startedByWorkflow` set, `startedByAgent` nil) *can*
use the tools, as the spec says.

## R8. The briefing (FR-012)

**Decision**: Add one line, `Briefing.helpers`, and include it only when the agent has the tools
(`lines(for:managesAgents:)`). Draft:

> If a piece of the work can go on alongside the rest, you can start up to three agents in this
> project with start_agent, and stop or archive them when their part is done. Do not start one
> for work you could simply do yourself.

**Rationale**: The briefing's own doc comment says an agent told six things follows the first two,
and that the tools are only described if the agent can actually use them. Helpers don't get this
line.

## R9. The daemon socket (out of scope, recorded)

The socket accepts any local process (`DaemonServer.swift:110`, `accept(listenFD, nil, nil)`, with
no peer check). This feature doesn't change that. The follow-up spec should consider
`getpeereid` plus separating the app's client from agent-spawned processes. It is noted in the
plan's risks.
