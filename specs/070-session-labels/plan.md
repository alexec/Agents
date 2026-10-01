# Implementation Plan: Session labels

**Branch**: `agents/speckit-specify-github-issue` | **Date**: 2026-09-29 | **Spec**: [spec.md](spec.md)

**Input**: Issue #50 and `specs/070-session-labels/spec.md`.

## Summary

Add owner-aware labels to the existing per-session `Agent` record. The daemon remains the
only writer: it validates and applies person and agent changes, persists the updated
record, and broadcasts it so Mac and Remote views update together. The project suggestion
list is derived from labels in that project's session records; labels with no remaining
session stop being suggested. MCP tools, workflow front matter, session discovery, list
filtering, and label chips all use the same normalized label model. See [research.md](research.md),
[data-model.md](data-model.md), [contracts/labels-tools.md](contracts/labels-tools.md), and
[quickstart.md](quickstart.md).

## Technical Context

**Language/Version**: Swift 6 with strict concurrency; SwiftUI.

**Primary Dependencies**:

- `AgentsKitCore` models and `DaemonAPI` wire payloads.
- `AgentsKit` daemon, `AgentStore`, and MCP `AppService`.
- Mac app and Remote app, both driven by daemon agent-change notifications.
- Workflow YAML front matter parsed by `WorkflowFile` and applied by `DaemonCore+Workflows`.

**Storage**: Typed label values are encoded in each `Agent` record (`agent.json`). The
daemon derives project suggestions by scanning that project's agents, including archived
sessions. No separate mutable label database is introduced. Existing records decode with
no labels. Owner values distinguish the person from the session's agent.

**Testing**: Swift Testing in `Packages/AgentsKit/Tests/AgentsKitTests`. The feature spec
defines independent scenario checks, so add unit and integration coverage for normalization,
limits, ownership refusals, persistence, MCP payloads, workflow starts, discovery, filtering,
and record propagation. Build the Agents and Remote schemes after implementation.

**Target Platform**: macOS, iPhone, iPad, and the Linux-hosted daemon for server projects.

**Project Type**: Swift macOS app, daemon and Swift package, with an iOS/iPadOS companion.

**Performance Goals**: Filtering a project of 200 sessions responds in under 1 second;
label changes propagate to connected views within 5 seconds (SC-002, SC-005).

**Constraints**:

- Preserve decoding of existing `agent.json` records and unknown fields.
- The daemon enforces ownership and label limits for every caller; UI and tool prose are
  not the authority.
- Updates go through the existing changed-agent persistence/broadcast path.
- Labels stay in the agent's project scope, including projects hosted on a server.
- A new chat that reads another session's history (065) has its own labels and starts
  without inherited labels.
- Person-selected labels travel in `DaemonAPI.StartRequest` and are saved on the initial
  `Agent` record before its first broadcast; helper/workflow starts assign agent ownership.
- Keep session titles and existing search behavior; parse `label:<value>` as an additional
  filter that combines with ordinary text search. Put the matcher in shared core logic so
  Mac and Remote use the same interpretation.
- Remote filtering must query archived records beyond the normal ten-at-a-time display
  page, so a label search covers the whole project.

**Scale/Scope**: Four user stories across the shared model/daemon, MCP contracts, workflow
front matter, Mac session list and prompt surface, and iPhone/iPad cards and chat surface.
Documentation changes are listed in the spec.

## Constitution Check

The current constitution (`.specify/memory/constitution.md`, version 1.2.1) requires a
specification, plan and ordered tasks; the daemon as sole state writer; app-owned user
control; inspectable work; synchronized docs; and build, test and documentation checks.
This plan follows those gates:

- **One persisted truth**: labels live on `Agent`, and all changes use the daemon's existing
  save-and-broadcast path.
- **One policy point**: normalization, canonical spelling, count/length validation, and
  owner checks live in shared core logic called by both person-facing and MCP mutations.
- **Compatibility**: decoding defaults absent labels to an empty list; unknown record fields
  and existing session behavior remain intact.
- **Project isolation**: suggestions are derived only from agents whose `projectFolder`
  matches the selected project; each host daemon owns its own records.
- **Accessible presentation**: owner difference is conveyed by fill/outline and text or
  accessibility wording, never color alone.
- **Quality and docs**: update every page in the spec's Docs section, run the package suite,
  build both schemes, and run `scripts/docs.sh check` before completion. Generated project
  changes go through `project.yml` and `xcodegen`, not direct edits to the Xcode project.

Re-checked after design: the plan keeps persistence under the daemon, leaves runtime
capabilities alone, and provides no cross-project label access.

## Project Structure

### Documentation (this feature)

```text
specs/070-session-labels/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/labels-tools.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/Agent.swift                       # backward-compatible persisted labels
├── Model/SessionLabel.swift                # normalized values, owner, shared policy
├── Model/SessionLabelQuery.swift           # shared Mac/Remote search interpretation
├── Model/WorkflowSettings.swift            # workflow labels setting
└── Daemon/DaemonAPI.swift                  # person start/mutation, helper and finish payloads

Packages/AgentsKit/Sources/AgentsKit/
├── Store/AgentStore.swift                  # whole-record save path, no new store
├── Daemon/DaemonCore+AppTools.swift         # validated finish_turn label changes
├── Daemon/DaemonCore+Helpers.swift          # start_agent labels
├── Daemon/DaemonCore+Sessions.swift         # person label mutation and discovery data
├── Daemon/DaemonCore+Workflows.swift        # parse/apply labels at workflow start
├── Daemon/DaemonCore+Commands.swift         # labels on initial session record
├── Daemon/DaemonCore+Dispatch.swift         # route label mutation method
├── Daemon/DaemonCore.swift                  # existing changed-agent broadcast
├── ACP/Serve/AppService.swift               # MCP schemas, validation and relay
└── Model/SessionLookup.swift                # label-aware session listing output

Daemon/Sources/main.swift                    # relay person label changes to daemon
App/Sources/AgentList/AgentRow.swift          # Mac session row labels and menu
App/Sources/Projects/SessionsColumn.swift     # label filter and empty state
App/Sources/Chat/ChatView.swift               # Mac chat label presentation/actions
App/Sources/Chat/PromptBar.swift              # new-session draft labels
App/Sources/AppModel.swift                    # Mac label actions and drafts
Remote/Sources/Projects/AgentCard.swift       # compact phone/iPad chips
Remote/Sources/Projects/ProjectPageView.swift # full-project label filtering
Remote/Sources/RemoteModel.swift              # Remote label actions and archived search
Remote/Sources/Chat/RemoteChatView.swift      # full labels and chat actions
Remote/Sources/StartAgent/StartAgentView.swift # Remote new-session labels

Packages/AgentsKit/Tests/AgentsKitTests/      # model, tool, daemon and workflow coverage
docs/reference/agent-tools.md
docs/how-to/label-a-session.md
docs/reference/workflows.md
docs/reference/statuses.md
docs/how-to/archive-park-stop.md
```

The implementation may split or rename files to match existing local patterns, but must
keep shared label policy in `AgentsKitCore` and persistence changes on the daemon path.
