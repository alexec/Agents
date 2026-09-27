# Implementation Plan: Client permission mode

**Feature**: 061-client-permission-mode | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md)
**Checkout**: main (existing shared checkout; feature artifacts selected with SPECIFY_FEATURE).

## Summary

Add independent Default / Auto-review controls for Cursor and Grok in Agent Runtimes. The daemon owns persistence and evaluates each new request against the agent's current working folder and initial Reach. Default retains cards; Auto-review answers only a single, clearly scoped action. Existing cards are never reconsidered.

## Technical Context

- Language: Swift 6.2; SwiftUI app, Foundation daemon, ACP JSON-RPC.
- Dependencies: existing AgentsKit and AgentsKitCore; no new dependencies.
- Storage: atomic client-permissions.json under StoreLocations.root; missing/corrupt data defaults to asking.
- Platforms: macOS 27; Linux daemon; iOS continues using existing permission cards.
- Testing: Swift Testing policy/store/daemon tests, scratch app RPC and settings inspection, server synchronization.
- Performance: local bounded parsing and filesystem scope checks; no network review or model call.
- Constraints: only Cursor/Grok; no prompt capsules; allow_once only; unknown actions ask; no home config edits.
- Scope: two controls, one shared classifier, persistence/API and host synchronization.

## Constitution Check

The repository constitution is an unfilled template and supplies no enforceable additional gates. Follow AGENTS.md, existing architecture, scoped filesystem permissions, and the spec. Pre-design check passes. Post-design check passes: Grok process-scoped override was verified against an existing always-approve configuration.

## Research gate

Grok must be forced to request permissions despite its saved mode. Its config overlay explicitly excludes permission settings. Verified `--permission-mode default` before `agent stdio` forces the permission request; see research.md. The existing overlay is not used for permission mode.

## Project Structure

- AgentsKitCore/Model/ClientPermissionSettings.swift: typed values and supported runtimes.
- AgentsKitCore/Model/ClientPermissionReview.swift: conservative pure request classifier using FolderScope.
- AgentsKit/Store/ClientPermissionStore.swift: durable daemon settings.
- AgentsKit/Daemon/DaemonCore+ClientPermissions.swift and DaemonCore.swift: settings and request decisions.
- AgentsKit/ACP/ACPSession.swift: preserve permission tool metadata.
- AgentsKitCore/Daemon/DaemonAPI.swift: settings state/set and changed notification.
- App/Sources/AppModel.swift: load/save and synchronize connected servers.
- App/Sources/Settings/AgentRuntimesSettingsView.swift: independent controls.
- AgentsKitCore/Runtimes/RuntimeCatalog.swift: verified Grok launch override.
- Packages/AgentsKit/Tests/AgentsKitTests: policy, persistence and protocol integration coverage.
- docs/reference/{settings,runtimes}.md and docs/how-to/{choose-runtime-model-mode,answer-a-question}.md: user guidance.

Paths above beginning AgentsKit or AgentsKitCore are beneath Packages/AgentsKit/Sources.

## Design

Use explicit settings fields cursor and grok, both Default. The setting is evaluated on every permission event, before creating a pending request or publishing attention events. For these two runtimes, replace the blanket app-tool auto-approval branch; other runtimes retain it. User-granted runtime allow-always choices remain runtime-owned. Automatic approvals never choose allow-always.

The classifier accepts structured file operations only when every declared target is inside FolderScope. Reject unknown tool identities even if their kind claims edit. Resolve relative paths against the command's validated working directory. Shell requests use a small grammar with known commands and options, rejecting shell control syntax, publishing, privilege escalation, global installation, ambiguous arguments, and out-of-reach paths. Project build/test scripts are treated as the requested ordinary project work, not a general-purpose shell sandbox.

The Mac persists the setting and sends it to connected server daemons and on reconnect; evaluation runs on the owning host so symlinks are checked on the correct filesystem. The Remote has no settings method access and continues handling existing cards.

## Complexity Tracking

No new service or dependencies. Reuse FolderScope, existing JSON-RPC roles, atomic StoreCoding, permission cards and runtime launch catalog.

