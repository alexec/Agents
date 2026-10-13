# Research: An agent writes a provider's tool map or commands

Decisions made from source at `4fc459aa`, without running anything. Each says what was chosen,
why, and what was not chosen.

## R1. How the control plane starts the agent

**Decision**: over a channel of the control plane's own to the host on its machine, as
`KeptRequests.attached` delivers a kept `agents/start` (`ControlRouter.deliverKept`). The
`StartRequest` gains one optional field, `purpose: AgentPurpose?`, with one case,
`.providerDraft(id:)`. The daemon reads it to (a) apply the writer tool policy, (b) bind the
writer's tools to the draft, and (c) leave the agent out of `agents/list` for clients
(FR-009). It is kept in the agent's record, so a daemon restart keeps the agent hidden.

**The host on its machine**: the host whose `HostRecord` says it runs beside the control plane.
On a Mac this is This Mac. The plan's first task finds how the router knows it (the local
host is the one the control plane started, or the one on its loopback channel). If there is
none, Write It for Me is off (spec, edge cases).

**Not chosen**: running a runtime from the control plane itself. The control plane has no ACP
code, and #058 keeps agents on hosts.

## R2. The writer tool policy

**Decision**: a second policy per runtime in `ToolPolicyCatalog`, `writer(for:)`. It removes
every tool that runs a command, writes a file, reaches the network or starts a subagent, on
top of the usual removals. For Claude: `Bash`, `BashOutput`, `KillShell`, `Write`, `Edit`,
`MultiEdit`, `NotebookEdit`, `WebFetch`, `WebSearch`, `Agent`, `Task`, and every `mcp__*`
connector except the app's own. `Read`, `Grep` and `Glob` stay: they see only the scratch
folder, which is empty except for what the control plane writes there.

A runtime is offered in the menu only when its `writer` policy has a lever that removes tools
(a deny list or an allow list), not `.words`. The research step of the tasks measures this per
runtime, as #015 did, and fills the catalog. Expected: Claude, Codex and Grok yes; the others
measured.

**Sandbox**: the agent starts with `sandbox: .on` where the runtime has one (#064), as a second
wall.

**Not chosen**: words only ("don't run commands"). A model that is told not to run a command
can still run it.

## R3. Where the writer's tools run

**Decision**: the daemon's `AppService` offers them (they are app tools, like `list_workspaces`)
only to an agent whose purpose is `.providerDraft`. The daemon relays each call on channel 0
as `host/providerDraft` with the agent's token and the draft id, as `host/workspaces` does.
`ProviderDrafts` checks that the draft's agent is the caller (FR-011), does the work, redacts
the answer, and records a step.

**Not chosen**: an MCP server per draft, run by the control plane and passed in `mcpServers`.
It would need a port or a pipe from the host to the control plane, which a cloud control plane
does not have for this; channel 0 is already there.

## R4. Redaction

**Decision**: `DraftRedaction` holds the draft's secrets. Every text bound for the agent (tool
lists, help, list results, failures) goes through it: each value is replaced with `${NAME}`.
Values of 6 characters or more are replaced wherever they are; shorter ones only as a whole
word. Values are also replaced in their URL-encoded and base64 forms, since a server may echo
a header. The same object redacts the draft's steps and log lines.

A test puts each secret into a server's tool description, an error, and a list result, and
checks that the agent's transcript, the log and the steps have none of them.

## R5. The safety rules for a check

**Decision** (FR-013, FR-014): `DraftSafety.listTool(_:in:)` and `DraftSafety.command(_:cli:)`
answer *run*, or *ask* with a reason. A *run* check goes ahead. An *ask* check becomes a
question in the sheet, as a start does (US3), with **Run Check**.

MCP annotations (`readOnlyHint`, `destructiveHint`) are read from `tools/list` when the server
sends them. Many do not, so the name rule applies as well.

**Not chosen**: asking before every check. Alex chose "checks it with one list, as the sheet
does now": a check is automatic when it is safe.

## R6. Start and stop proofs

**Decision**: `prove_start` and `prove_stop` take a workspace id from the last list. The draft
goes to state `asking` and sends `control/providerDraft` to the Mac that owns the sheet. The
tool call waits for `providers/draftAnswer`, at most 2 minutes. A yes calls the draft's start
or stop once, through a `ProviderConnection` made from the draft, with the contract's long
timeout (10 minutes). The draft's 5-minute limit stops while it waits for the person and while
a start or stop runs.

A workspace linked to a host is checked as `hosts/stop` checks it (agents working, refuse).

## R7. The agent's prompt

**Decision**: a fixed prompt, kept in `ProviderDrafts`, with: the goal (a tool map or a
command-provider config); the format pages (`contracts/tool-map.md` or
`contracts/command-provider.md` of #691, copied into the scratch folder as files); the secrets'
names; the old map and its problem in Edit…; and the rules (check before you send; ask before
start or stop; send with `send_draft`). The agent's last `send_draft` is the result.

## R8. Shipped maps and presets first

**Decision**: before an agent starts, `ProviderDrafts` checks the cheap answers: the server
follows the contract (US1 AS5), the shipped DigitalOcean map's tools are all in `tools/list`
(US1 AS6), or the CLI is a preset's (US2 AS6). Each answers at once, with no agent.

## R9. The sheet's channel

**Decision**: `control/providerDraft` goes only to the client session that sent
`providers/draftStart`. If that session goes (the Mac sleeps, the window closes), the draft
is cancelled after 30 seconds, and its agent stops.
