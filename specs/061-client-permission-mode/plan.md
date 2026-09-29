# Implementation Plan: Client permission mode

**Feature**: 061-client-permission-mode | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md)
**Checkout**: main (existing shared checkout; feature artifacts selected with SPECIFY_FEATURE).

## Summary

Add independent Default / Always-approve controls for Cursor and Grok in Agent Runtimes. The daemon owns persistence and, under Always-approve, answers every new permission request that offers allow-once (preferred) or only allow-always. Default retains cards. Existing cards are never reconsidered. An earlier Auto-review classifier was removed after it still interrupted ordinary turns; stored `autoReview` migrates to Always-approve on load.

## Technical Context

- Language: Swift 6.2; SwiftUI app, Foundation daemon, ACP JSON-RPC.
- Dependencies: existing AgentsKit and AgentsKitCore; no new dependencies.
- Storage: atomic client-permissions.json under StoreLocations.root; missing/corrupt data defaults to asking.
- Platforms: macOS 27; Linux daemon; iOS continues using existing permission cards.
- Testing: Swift Testing store/daemon tests, scratch app RPC and settings inspection, server synchronization.
- Performance: local option lookup only; no network review or model call.
- Constraints: only Cursor/Grok; no prompt capsules; prefer allow_once; questions that are not permission still wait; no home config edits.
- Scope: two controls, persistence/API and host synchronization.

## Constitution Check

The repository constitution is an unfilled template and supplies no enforceable additional gates. Follow AGENTS.md, existing architecture, scoped filesystem permissions, and the spec. Pre-design check passes. Post-design check passes: Grok process-scoped override was verified against an existing always-approve configuration.

## Research gate

Grok must be forced to request permissions despite its saved mode. Its config overlay explicitly excludes permission settings. Verified `--permission-mode default` before `agent stdio` forces the permission request; see research.md. The existing overlay is not used for permission mode.

## Project Structure

- AgentsKitCore/Model/ClientPermissionSettings.swift: typed values, migration from `autoReview`, and supported runtimes.
- AgentsKit/Store/ClientPermissionStore.swift: durable daemon settings.
- AgentsKit/Daemon/DaemonCore+ClientPermissions.swift and DaemonCore.swift: settings and request decisions.
- AgentsKit/ACP/ACPSession.swift: preserve permission tool metadata.
- AgentsKitCore/Daemon/DaemonAPI.swift: settings state/set and changed notification.
- App/Sources/AppModel.swift: load/save and synchronize connected servers.
- App/Sources/Settings/AgentRuntimesSettingsView.swift: independent controls.
- AgentsKitCore/Runtimes/RuntimeCatalog.swift: verified Grok launch override.
- Packages/AgentsKit/Tests/AgentsKitTests: persistence and protocol integration coverage.
- docs/reference/{settings,runtimes}.md and docs/how-to/{choose-runtime-model-mode,answer-a-question}.md: user guidance.

Paths above beginning AgentsKit or AgentsKitCore are beneath Packages/AgentsKit/Sources.

## Design

Use explicit settings fields cursor and grok, both Default. The setting is evaluated on every permission event, before creating a pending request or publishing attention events. For these two runtimes under Always-approve, answer with the first allow-once option, else allow-always. User-granted runtime allow-always choices remain runtime-owned. Automatic approvals prefer allow-once so Default still asks after a switch back.

The Mac persists the setting and sends it to connected server daemons and on reconnect. The Remote has no settings method access and continues handling existing cards.

## Complexity Tracking

No new service or dependencies. Reuse existing JSON-RPC roles, atomic StoreCoding, permission cards and runtime launch catalog. The reach-based classifier (`ClientPermissionReview`) was removed with Auto-review.
