# Tasks: Client permission mode

**Input**: spec.md, plan.md, research.md, data-model.md, contracts/permissions.md.

## Phase 1: Setup

- [X] T001 Verify project ignores and implementation prerequisites in .gitignore and specs/061-client-permission-mode/.

## Phase 2: Foundation

- [X] T002 Add settings model ("exactly default and autoReview", both default) in Packages/AgentsKit/Sources/AgentsKitCore/Model/ClientPermissionSettings.swift and atomic persistence in Packages/AgentsKit/Sources/AgentsKit/Store/ClientPermissionStore.swift.
- [X] T003 Add control-only state/set RPC and changed notification in Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift and Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+ClientPermissions.swift.
- [X] T004 Preserve permission name, locations and diffs in Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift.

## Phase 3: US1 — ordinary work (P1)

Independent check: Cursor Auto-review accepts an in-reach edit and test, while Grok Default waits.

- [X] T005 [US1] Add boundary and ordinary-action tests in Packages/AgentsKit/Tests/AgentsKitTests/Unit/ClientPermissionReviewTests.swift, covering extra folders and worktrees.
- [X] T006 [US1] Implement file and command classifier in Packages/AgentsKit/Sources/AgentsKitCore/Model/ClientPermissionReview.swift using FolderScope; "Approval requires an offered allow_once option".
- [X] T007 [US1] Apply current settings before pending cards in Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift and verify no permission attention events in Packages/AgentsKit/Tests/AgentsKitTests/Integration/ClientPermissionTests.swift.

## Phase 4: US2 — Default and live changes (P1)

Independent check: missing settings ask; switching back asks again; an existing card survives.

- [X] T008 [US2] Force Grok default at launch in Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/RuntimeCatalog.swift, preserving terminal config.
- [X] T009 [US2] Verify persistence, per-runtime independence, corrupt fallback and live pending-card behavior in Packages/AgentsKit/Tests/AgentsKitTests/Integration/ClientPermissionTests.swift.

## Phase 5: US3 — boundaries (P2)

Independent check: outside paths, publish, sudo and app control tools remain pending.

- [X] T010 [US3] Validate ambiguous/mixed commands, symlink escapes, publishing, privileged actions and app tools in Packages/AgentsKit/Tests/AgentsKitTests/Unit/ClientPermissionReviewTests.swift; verify ordinary permission-card delivery in Packages/AgentsKit/Tests/AgentsKitTests/Integration/ClientPermissionTests.swift.

## Phase 6: US4 — Settings and hosts (P2)

Independent check: both controls persist, appear when uninstalled, propagate to host requests, and add no prompt/Remote controls.

- [X] T011 [US4] Add load/save/notification handling and server synchronization in App/Sources/AppModel.swift.
- [X] T012 [US4] Add independent runtime-row pickers and descriptions in App/Sources/Settings/AgentRuntimesSettingsView.swift.
- [X] T013 [US4] Build and exercise scratch app settings and server propagation following specs/061-client-permission-mode/quickstart.md.

## Phase 7: Polish

- [X] T014 [P] Update docs/reference/settings.md, docs/reference/runtimes.md, docs/how-to/choose-runtime-model-mode.md and docs/how-to/answer-a-question.md.
- [X] T015 Run relevant package suites, docs check and scratch validation; record evidence in specs/061-client-permission-mode/quickstart.md and clean scratch processes.

## Dependencies and parallel work

T001 → T002 → T003 → T004; then US1 → US2 → US3 → US4 → final validation.
US1 classifier tests precede implementation; US2 launch work can run alongside persistence validation; US3 unit and daemon tests can be independent once the classifier is complete. US4 UI work can follow the settings model while host synchronization is implemented, but their shared AppModel edits must be sequential. T014 can run alongside UI validation.

## Implementation strategy

The MVP is US1 with the fail-closed US3 boundary already enforced; do not ship ordinary approval without its boundary. Deliver and verify remaining stories incrementally. All stories are included in this implementation. Tests are warranted by the specification's explicit acceptance scenarios and the permission boundary.
