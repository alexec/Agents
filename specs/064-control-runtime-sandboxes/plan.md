# Implementation Plan: Control runtime sandboxes

**Feature**: 064-control-runtime-sandboxes | **Date**: 2026-09-28, revised 2026-09-29 (#40) | **Spec**: [spec.md](spec.md) | **Look**: [look/look.md](look/look.md) (approved by Alex, 2026-09-29)
**Branch**: `agents/work-github-issue-40`, a worktree off main.

## Summary

Each runtime with a measured route gets a saved command-sandbox default (**As configured by runtime** / **On** / **Off**; Gemini without On), and each agent an optional override. The daemon resolves the choice at every spawn, and because every turn releases its process, a change applies from the next turn. The route is launch arguments (Grok), environment (Gemini), the session's `_meta` (Claude) or the mode (Codex). Cursor, Copilot, Antigravity and OpenCode show their state and why, with no control.

A sandbox that failed to set up is recognised from real failure text in three shapes: the runtime will not start, a command failed and the turn went on, or Gemini never answered. The agent stops with a card, at once for the first shape and when the turn ends for the second. **Continue without sandbox** sets only that agent's override to Off and re-sends the task. Nothing retries with broader access until the person chooses it.

What changed since 2026-09-28 (research R9, Alex's decisions): no in-app probe; Claude has a route (`_meta.claudeCode.options.sandbox`); Cursor's flag is not read under ACP; Copilot waits for its quota; Gemini has Off only and a hang to recognise; Antigravity and OpenCode have no sandbox the app can reach; mid-turn failures show at the end of the turn.

## Technical Context

- **Language**: Swift 6.2. SwiftUI for the Mac app and Remote, Foundation for the daemon (Mac and Linux agentsd), ACP JSON-RPC.
- **Dependencies**: none new.
- **Storage**: `<root>/sandbox-settings.json` (`SandboxSettingsStore`, a copy of `ClientPermissionStore`): runtime defaults only. A missing or unreadable file means every runtime as configured. The override and effective state are on the agent record.
- **Platforms**: macOS 27, the Linux agentsd, iOS/iPadOS Remote.
- **Testing**: Swift Testing with `FakeLauncher` and `FakeACPAgent`; the fixtures in `Tests/AgentsKitTests/Fixtures/sandbox-failures/`; `scripts/sandbox-probe.sh` for the live routes; run-app on a scratch root; test-servers on the devbox.
- **Constraints**: never write a runtime's settings files (FR-016); never widen access silently; folder scope, tool policy and client permissions untouched (FR-009); a helper never looser than its caller (R10).

## Constitution Check

The constitution is an unfilled template. The plan follows AGENTS.md and the spec. Passes before and after design.

## Built for the look (a0d9cfeb)

- `SandboxChoice`, `SandboxState`, `EffectiveSandbox`, `SandboxSettings`, `SandboxFailureRecord` (AgentsKitCore/Model/SandboxSettings.swift).
- `SandboxCatalog` (routes, measured versions, failure patterns, `choices`, `state`) and `SandboxWords` (every sentence).
- `sandbox/state`, `sandbox/set`, `agents/setSandbox` (Codex's mode moved with it), `agents/answerSandbox` declared; `sandbox/changed`.
- `Agent.sandboxOverride`, `Agent.effectiveSandbox`; `StartRequest.sandbox`.
- `TranscriptEntry.Kind.sandboxFailure`, a block a concise turn shows.
- Mac: the Settings section, the prompt-bar `SandboxCapsule`, the `SandboxFailureCard` with `ChatActions.continueWithoutSandbox` and `keepStopped`.

## To build

### Resolution and launch

1. `DaemonCore.resolvedSandbox(for agent:, caller:)`: the override, else the runtime default, else `runtime`; a choice the catalog does not offer becomes `runtime`. Helper cap: if the caller's effective state is On, Off becomes `runtime` with the reason "Limited by the agent that started it".
2. A TaskLocal `LaunchSandbox.value: SandboxChoice` bound around `launcher.launch` in `freshSession`, `liveSession` and `options()` (drafts carry `OptionsRequest.sandbox`; a draft is reused only when its choice matches).
3. `ProcessSessionLauncher.launch` puts Grok's arguments before the runtime's own and merges Gemini's environment last.
4. Claude: `_meta.claudeCode.options.sandbox = {"enabled": Bool}` added where the app builds its `disallowedTools`/`plugins` `_meta`, on `session/new` and on every `session/load` or resume (the adapter rebuilds its process when it changes).
5. Codex: a start whose resolved choice is Off starts in `agent-full-access`; On from Full access starts in `read-only` (FR-005c). `setOption` of the mode already writes the override (built).
6. `effectiveSandbox` written after each handshake from `SandboxCatalog.state` (Codex from the mode in force).

### Failure

7. `SandboxFailureDetector` (AgentsKitCore, pure): given a runtime id and text, whether it is a sandbox setup failure, and the trimmed detail. Tested against every fixture, including the `not-*` ones.
8. Where it looks:
   - **Will not start**: the handshake or `session/new` error, the `liveSession` catch, and the last 8 KB of stderr, which `ACPSession` now keeps. The agent ends `sandboxFailed` at once. A new agent's start answers `sandboxWillNotStart` too, and the form keeps the prompt.
   - **Mid-turn**: completed tool calls' output during the turn, and for Codex the turn's reply text; remembered on the turn and acted on in `finishTurn`: the agent ends `sandboxFailed` after the turn's own ending (FR-006a).
   - **Hang**: Gemini's handshake timing out with no `initialize` answer, when its resolved choice is not Off.
   - Checked before sign-in, allowance and generic handling; never for a command denied inside a working sandbox.
9. `EndedReason.sandboxFailed`: stopped, needs the person (the Blocked group), never retried by the app.
10. The `.sandboxFailure` entry: `recoveryOffered = SandboxCatalog.canTurnOff`, `completedToolCalls` from the failed turn.

### Recovery

11. `agents/answerSandbox {agentID, carryOn}`: refused unless the agent's latest `.sandboxFailure` is pending. `carryOn: false` marks it `keptStopped`. `carryOn: true` sets the override to Off (Codex: Full access), marks it `continued`, and re-sends the last prompt with `beginTurn(recorded: false)` like Pool's `retry`, or "The command sandbox is now off. Carry on with the task." after completed tool calls (R12).

### Surfaces

12. Mac: done for the look; the start form's retry after `sandboxWillNotStart` offers **Start without sandbox**.
13. Remote: `SandboxCapsule` in its prompt bar and start form (`ChoiceRows`), `RemoteModel` calls, and `ChatActions` for the card. Build for the generic simulator only; the look on devices is Alex's.
14. Servers: the Mac pushes defaults on change and on connect (built); each server resolves with its own catalog. Walk Claude's failure and Codex's on the devbox.

### Docs

15. `docs/reference/runtimes.md` (the Sandbox rows and a "Command sandbox" section), `docs/reference/settings.md`, `docs/how-to/choose-runtime-model-mode.md`, `docs/how-to/answer-a-question.md`.

## Requirement coverage

| Requirement | Where |
|---|---|
| FR-001, FR-013, FR-014, FR-015 | `SandboxCatalog`, `SandboxWords`, Settings section, capsule |
| FR-002 | Catalog holds measured routes only; `setSandboxSettings` and `setSandbox` refuse others |
| FR-003, FR-003c, SC-006 | Missing default is `runtime`; nothing added to the launch for it |
| FR-003a, FR-003b, FR-011 | Resolution in the daemon at every spawn; `agents/setSandbox` with nil; helper cap |
| FR-004, FR-005, FR-005a–c | Separate capsule; Codex mode coupling both ways |
| FR-006, FR-006a, FR-006b | Detector, three shapes, fixtures |
| FR-007, FR-007a | Card, `agents/answerSandbox`, no automatic retry |
| FR-008 | Catalog states; managed policies noted in `why` |
| FR-009, SC-007 | Only runtime args, env and `_meta` change |
| FR-010 | `effectiveSandbox` after each handshake; capsule on Mac and Remote |
| FR-012 | Resolution at spawn; `releaseRuntime` every turn; "Applies from its next turn" |
| FR-016 | No runtime file is written |

## Complexity Tracking

No new service or dependency. Reuses the `clientPermissions` store, RPC and push; the `LentEnvironment` TaskLocal pattern; `ModeLooseness`; the `SwitchNote` card look; Pool's resend path. The only new mechanism is the detector, and it is a table of strings from real failures.
