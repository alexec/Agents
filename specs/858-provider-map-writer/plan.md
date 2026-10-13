# Implementation Plan: An agent writes a provider's tool map or commands

**Branch**: `agents/issue-858-at-add` | **Date**: 2026-10-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/858-provider-map-writer/spec.md` (issue #858).

Planned from source at `4fc459aa` (main), without building or running anything. The decisions
are in [research.md](research.md), the records in [data-model.md](data-model.md), the
interfaces in [contracts/](contracts/), the sheet in [contracts/layouts.md](contracts/layouts.md)
and the walk in [quickstart.md](quickstart.md).

## Summary

#691 gave the control plane providers (`ControlPlaneKit/Providers/`): `ProviderConnection`
connects to a server and checks it, `ToolMapping` reads a tool map, `ProviderSecrets` keeps
secrets in a 0600 file, and `WorkspaceProviders` answers `providers/*`. The Add Provider sheet
(`App/Sources/Control/ControlProvidersPage.swift`) sends `providers/add`, which checks and
keeps in one step.

This feature adds a **draft** between the form and Add:

1. **`ProviderDrafts`** (a new actor in `ControlPlaneKit/Providers/`) holds each Write It for
   Me in memory: the form so far, its secrets, the agent, its steps and its last draft. It is
   given to `WorkspaceProviders`, which routes the new methods to it.
2. **What it reads**: for an MCP server, a `ProviderConnection` made from the form, which reads
   `tools/list` with its schemas and annotations (a new `tools()` on the connection). For a
   CLI, `ChildProcess` runs `‹cli› --help` in the control home, as the command provider runs
   its commands.
3. **The agent**: the control plane starts it on the host on its own machine, over a channel of
   its own, as `KeptRequests` delivers a kept `agents/start` (`router.deliverKept`). The start
   request names a scratch folder in the control home, the runtime from the sheet, a
   **writer** tool policy (research R2), and a token that binds the writer's tools to this
   draft.
4. **The writer's tools** ([contracts/writer-tools.md](contracts/writer-tools.md)) are app tools
   in `AppService`, offered only to an agent started with the writer policy. The daemon relays
   them to the control plane on channel 0, as #691 US6 relays the workspace tools
   (`host/workspaces` → a new `host/providerDraft`). Each answer is redacted by
   `ProviderDrafts` before it leaves the control plane.
5. **Checks** call the same `ProviderConnection.check()` as Add, on a connection made from the
   draft, after the safety rules (FR-013, FR-014). Start and stop proofs are a question in the
   sheet: a `control/providerDraft` notification with an `asking` state, and
   `providers/draftAnswer` from the Mac.
6. **The sheet** (Mac only): Write It for Me, the runtime menu, the step line, Details, the
   question, and the draft into the form's fields (layouts L10). **Add** is unchanged.
7. **Authorship**: `ProviderRecord.writtenBy`, set by `providers/add` when the request carries
   the draft id and its map or config is the draft's, unchanged.

Start, Stop, list, Start when used and Stop when idle do not change.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of the repo.

**Primary Dependencies**: `ControlPlaneKit` (providers, router), `AgentsKit` (`MCPToolClient`,
`ChildProcess`, `AppService`, `ToolPolicyCatalog`, `DaemonCore`), `AgentsKitCore` (`DaemonAPI`),
SwiftUI in `App/`.

**Storage**: none new on disk, except `writtenBy` in the provider record
(`v1/providers/<id>.json`) and the writer's scratch folder (`<control home>/drafts/<id>/`),
deleted when the draft ends. The agent's transcript is kept by its daemon as every agent's is.

**Testing**: Swift Testing in `Packages/ControlPlane/Tests/ControlPlaneKitTests` (drafts,
redaction, the safety rules, the question) and `Packages/AgentsKit/Tests` (the writer policy,
the relayed tools). A stand-in runtime (the test runtime `AgentsKit` tests already use) writes a
fixed draft. One walk on a scratch app (run-app) with the real default runtime.

**Target Platform**: the control plane on macOS and Linux; the sheet on macOS.

**Project Type**: desktop app + daemon + control plane (existing).

**Performance Goals**: SC-001/SC-002, a passing draft in under 2 minutes. Each tool answers in
the time of its call (help and list: 25 s at most).

**Constraints**: no secret value in any text the agent gets, any log line, or the transcript
(FR-022, FR-024). No start or stop without a yes (FR-018). No model call at run time (FR-025).

**Scale/Scope**: one draft per sheet; a draft lives at most 5 minutes; at most 8 checks and 40
tool calls.

## Constitution Check

- **I. Spec-led**: spec, clarifications (Alex, 2026-10-12), this plan, then tasks. Pass.
- **II. Capability-driven**: the runtime menu offers only runtimes whose tool policy can turn
  their own tools off (`ToolPolicy.lever`), not a list of names. Pass.
- **III. Scoped access**: the agent's folder is a scratch folder; its tools are the writer's
  only; every start or stop is the person's yes, in the sheet. Secrets stay with the control
  plane. Pass.
- **IV. Inspectable**: the step line and Details show every call and its result; the
  transcript is kept 7 days; the record says an agent wrote the map. Pass.
- **V. Docs and quality**: four docs pages in the spec's Docs; `generated.ts` is not touched
  (no web rows). Pass.

## Project Structure

### Documentation (this feature)

```text
specs/858-provider-map-writer/
├── spec.md
├── plan.md            # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── control-methods.md
│   ├── writer-tools.md
│   └── layouts.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/ControlPlane/Sources/ControlPlaneKit/Providers/
├── ProviderDrafts.swift          # new: drafts, their agent, steps, checks, questions
├── DraftRedaction.swift          # new: secret values → ${NAME}
├── DraftSafety.swift             # new: FR-013 and FR-014
├── ProviderConnection.swift      # + tools(): names, descriptions, schemas, annotations
└── WorkspaceProviders.swift      # routes providers/draft*; writtenBy on add

Packages/AgentsKit/Sources/AgentsKitCore/
├── Control/ProviderDraftAPI.swift   # new: methods, requests, the notification
├── Model/AppTool.swift              # + the writer's tools
└── Runtimes/ToolPolicyCatalog.swift # + the writer policy per runtime

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift                # offers the writer's tools to a writer only
└── Daemon/DaemonCore+ProviderDraft.swift     # new: relays them on channel 0

App/Sources/Control/
├── ControlProvidersPage.swift    # Write It for Me, CLI field, refusal button, Edit…
└── ProviderDraftView.swift       # new: step line, Details, question, result lines
```

**Structure Decision**: the draft lives with the providers on the control plane, because the
server, the CLI and the secrets are there. The agent's side is the existing app-tool path of
#691 US6. Only the Mac draws it.

## Complexity Tracking

| Addition | Why it is needed | Simpler choice not taken, and why |
|---|---|---|
| A new tool policy, "writer" | The agent must not run commands or reach the network with the person's sign-ins (FR-010). | The usual policy: it leaves Bash and web tools on, so the agent could run the CLI itself, with the person's credentials. |
| A question in the sheet, not on the agent's card | The agent has no chat on screen (Alex chose the sheet). | The question card: it would show in a chat the person can't see. |
| Safety rules before a check (FR-013, FR-014) | A check calls a tool or a command the agent chose. | Run every check: an agent could name `droplet-delete` as its list. |
