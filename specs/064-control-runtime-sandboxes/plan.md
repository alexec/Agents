# Implementation Plan: Control runtime sandboxes

**Feature**: 064-control-runtime-sandboxes | **Date**: 2026-09-28 | **Spec**: [spec.md](spec.md) | **Wireframes**: [wireframe.md](wireframe.md)
**Checkout**: main (existing shared checkout; feature artifacts selected with `.specify/feature.json`). Build in a worktree off main.

## Summary

Give each runtime a saved command-sandbox default (**As configured by runtime** / **On** / **Off**) and each agent an optional override. The daemon resolves the effective choice whenever it launches a runtime process. Because every turn releases its process, a change applies from the next turn. A runtime expresses the choice either through launch arguments or environment (Grok, Cursor, Copilot, Gemini), through its mode (Codex: Off is **Full access**), or not at all (Claude until verified; Antigravity Unavailable).

A sandbox that cannot start is recognised separately from other failures. The agent stops with a card. The person can choose **Continue without sandbox**, which sets only that agent's override to Off and re-sends the task. Nothing retries with broader access until the person chooses it.

## Technical Context

- **Language**: Swift 6.2. SwiftUI for the Mac app and Remote, Foundation for the daemon (Mac and Linux agentsd), ACP JSON-RPC.
- **Dependencies**: existing AgentsKit and AgentsKitCore. No new dependencies.
- **Storage**: `<root>/sandbox-settings.json` holds the runtime defaults and per-host probe results. It is written atomically with StoreCoding, like `client-permissions.json`. A missing or corrupt file means every runtime is **As configured by runtime**. The agent override and effective state live on the agent record.
- **Platforms**: macOS 27 (Mac app and daemon), the Linux agentsd on servers, and iOS/iPadOS Remote.
- **Testing**:
  - Swift Testing unit and integration suites with `FakeLauncher` and `FakeACPAgent`
  - failure fixtures under `Tests/AgentsKitTests/Fixtures/sandbox-failures/`
  - live probes per runtime ([research.md](research.md) R2–R7)
  - the run-app skill on a scratch root
  - the test-servers skill on the devbox
- **Performance**: a dictionary lookup per launch. The probe runs once per runtime version per host, never per turn.
- **Constraints**:
  - Never edit a runtime's own home config: no `~/.grok`, `~/.copilot`, `~/.cursor` or `~/.codex` writes.
  - Never widen access silently. An unconfirmed or rejected Off shows **Unavailable**.
  - Folder scope, tool policy and client permission decisions are untouched (FR-009).
  - A helper is never looser than the agent that started it.
- **Scope**:
  - seven runtimes
  - one Settings row per runtime
  - an override in the Mac and Remote start forms and in the prompt bar of a running agent
  - a state capsule in the conversation
  - a recovery card
  - daemon API and server sync
  - four docs pages

## Constitution Check

The repository constitution is an unfilled template and supplies no enforceable gates. The plan follows AGENTS.md, the existing architecture and the spec.
- **Pre-design**: passes.
- **Post-design**: passes, subject to the research gate below.

## Research gate

Offering an Off or On choice needs evidence that the exact integration honours it (FR-002). The flags were confirmed to parse on this Mac (2026-09-28): Grok 1.0.41 `--sandbox off`, Cursor 2026.09.26 `--sandbox disabled`, Copilot 1.0.89-5 `--no-sandbox`. That they take effect under ACP is not yet shown.

The first implementation task is a live probe per runtime on the Mac and on the devbox ([research.md](research.md) R9). A runtime whose probe fails ships with **As configured by runtime** only, shown as **Runtime controlled**. Codex needs no launch probe because its Off route is its own advertised mode. It still needs the failure text captured.

## Project Structure

Paths beginning AgentsKit or AgentsKitCore are beneath `Packages/AgentsKit/Sources`.

**New files**
- AgentsKitCore/Model/SandboxSettings.swift: `SandboxChoice`, `SandboxSettings`, `SandboxProbe`, `EffectiveSandbox`, `SandboxFailureRecord`. See [data-model.md](data-model.md).
- AgentsKitCore/Runtimes/SandboxCatalog.swift: per-runtime route (launch args, env, mode, meta or none), failure patterns, whether approvals are coupled, and the Settings wording.
- AgentsKit/Store/SandboxSettingsStore.swift: a copy of `ClientPermissionStore`.
- AgentsKit/Daemon/DaemonCore+Sandbox.swift: settings state and set, capability per host, `resolvedSandbox(for:)`, the probe, and `continueWithoutSandbox`.
- Shared/UI/Chat/SandboxFailureCard.swift: the transcript card, modelled on `SwitchNote`.

**Changed files**
- AgentsKitCore/Model/Agent.swift: `sandboxOverride`, `effectiveSandbox`. Add both to `CodingKeys`, `init(from:)` and `encode`.
- AgentsKitCore/Model/EndedReason.swift: `sandboxFailed`.
- AgentsKitCore/Model/TranscriptEntry.swift: `.sandboxFailure(SandboxFailureRecord)`.
- AgentsKitCore/Daemon/DaemonAPI.swift:
  - `sandbox` on `StartRequest` and `OptionsRequest`
  - the `sandboxWillNotStart` error code
  - the `sandbox/*` and `agents/setSandbox` / `agents/continueWithoutSandbox` methods
  - the `sandbox/changed` notification

  See [contracts/daemon-api.md](contracts/daemon-api.md).
- AgentsKit/Daemon/DaemonCore.swift:
  - `Draft` carries the resolved choice and is only reused when it matches.
  - A TaskLocal `LaunchSandbox` is read by `ProcessSessionLauncher.launch`, which appends catalog args and env after the policy layers.
  - `.standardError` keeps the last 8 KB per live session.
- AgentsKit/Daemon/DaemonCore+Commands.swift:
  - Resolve and bind `LaunchSandbox` in `freshSession`, `liveSession` and `options()`.
  - Record `effectiveSandbox` after the handshake.
  - Classify in `startFailure`, the `liveSession` catch, `turnFailed` and `finishTurn`, before sign-in, limit and generic handling.
  - Codex: map the choice to the start mode in `start`, and write the override in `setOption`.
- AgentsKit/Daemon/DaemonCore+Workflows.swift and DaemonCore+Helpers.swift: no new settings. The daemon resolves them itself. Add the helper cap in `startHelper`.
- AgentsKit/Daemon/DaemonCore+Dispatch.swift and the connection roles: route the new methods. `sandbox/set` is control-only. `agents/setSandbox` and `agents/continueWithoutSandbox` are also device methods.
- Shared/UI/Chat/PromptPieces.swift: the sandbox capsule in `PromptHeader`.
- Shared/UI/Chat/ChatActions.swift: `keepStopped` and `continueWithoutSandbox`.
- App/Sources/Settings/AgentRuntimesSettingsView.swift: `SandboxDefaultRow` for every runtime, including the Antigravity Unavailable row.
- App/Sources/Chat/PromptBar.swift: a Sandbox `OptionMenu` beside the mode in `optionsRow`, for drafts and live agents.
- App/Sources/AppModel.swift:
  - `sandboxState`
  - refresh and set
  - `pushSandboxSettingsToServers` on change and on reconnect
  - the start-form retry after `sandboxWillNotStart`
- Remote/Sources/StartAgent/ChoiceRows.swift and RemoteModel: a Sandbox row. Remote PromptBar: the override menu. RemoteChatView: fill the card's `ChatActions`.
- Tests under Packages/AgentsKit/Tests/AgentsKitTests:
  - Unit/SandboxSettingsTests
  - Unit/SandboxCatalogTests (args and env per choice; failure classification against fixtures)
  - Integration/SandboxLaunchTests
  - Integration/SandboxRecoveryTests
  - Integration/SandboxHelperCapTests
- Docs: docs/how-to/choose-runtime-model-mode.md, docs/reference/runtimes.md, docs/reference/settings.md, docs/how-to/answer-a-question.md.

## Design

### Resolution

The daemon resolves the choice, never the client. That way manual starts, workflows and helpers agree (FR-011). The order is:
1. The agent's override, if set.
2. The runtime's default, if the capability allows it on this host.
3. **As configured by runtime**.

The helper cap then applies. If the calling agent's effective sandbox is On, a helper cannot resolve to Off. It falls back to **As configured by runtime**; for Codex, the existing ModeLooseness refusal keeps it out of Full access. Its reason reads "limited by the agent that started it". Resolution happens at every spawn: the draft in `options()`, `start`, and `liveSession` on every resumed turn. `finishTurn` always releases the process, so a changed default or override takes effect at the next turn and never mid-command (FR-012). A change made while a turn runs gets the reply "applies from the next turn".

### Routes

| Runtime | Off | On | As configured | Couples approvals |
|---|---|---|---|---|
| Codex | mode `agent-full-access` | mode `read-only` when leaving Full access; `agent` or `read-only` otherwise | the mode decides: On unless Full access | yes: Full access removes prompts |
| Grok | `--sandbox off` | `--sandbox workspace` | no flag; Runtime controlled | no |
| Cursor | `--sandbox disabled` | `--sandbox enabled` | no flag; Runtime controlled | no |
| Copilot | `--no-sandbox` | `--sandbox` | no flag; Runtime controlled | no |
| Gemini | `GEMINI_SANDBOX=false` | `GEMINI_SANDBOX=true` | no env; Runtime controlled | no |
| Claude | none until R7 is verified | none until verified | Runtime controlled | no |
| Antigravity | Unavailable (FR-013) | Unavailable | Unavailable | — |

**Codex coupling (FR-005a–c)**
- Choosing Off selects Full access.
- Choosing On from Full access selects **Ask for approval** and says approval prompts return.
- A mode change writes the matching override, so the mode and the sandbox never disagree.
- A runtime default of Off starts inheriting Codex agents in Full access. It is applied in the daemon, not through `ModeMemory`, which only pre-fills forms.

### Capability

`SandboxCatalog` states what a runtime could do. The per-host probe result for the installed version states what it did do. A choice is actionable only when both agree. A version change invalidates the probe. Until the probe runs again, a saved Off shows **Unavailable** and the runtime starts **As configured**, never wider (the spec's edge case). A Copilot startup warning that a managed policy forces sandboxing marks Off **Unavailable (policy)** (FR-008, US3-4).

### Failure

`SandboxCatalog.failurePatterns` for each runtime are matched against three sources: the handshake error, the turn's error text (`RuntimeLaunch.turnError`) and the session's recent stderr. They are checked before sign-in, limit and generic handling. Authentication, approval refusal, folder scope and in-sandbox command denials never match (FR-006). A denied tool call is a tool result, not a turn failure, so the patterns only match text that means the sandbox did not come up.

On a match:
- the agent ends `sandboxFailed`
- a `.sandboxFailure` record is written with `recoveryOffered` only if Off is actionable for this runtime and host
- the agent stays stopped (FR-007a)

If a new agent's `session/new` fails this way, the start request returns `sandboxWillNotStart`. The form keeps the prompt and offers **Start without sandbox**, which resubmits with override Off.

### Recovery

`agents/continueWithoutSandbox`:
- sets this agent's override to Off (Codex: Full access)
- records a note
- re-sends the last user prompt from the transcript with `beginTurn(recorded: false)`, following `retry`/`sendAgain` in DaemonCore+Pool.swift

If tool calls completed in the failed turn, it sends "The command sandbox is now off. Carry on with the task." instead, and the card said so beforehand. **Keep stopped** only dismisses the card. That is at most two actions on the Mac: read, then click (SC-005).

### Surfaces

- **Mac Settings**: one row per runtime page, with a supporting line from the catalog (FR-014).
- **Mac start form and prompt bar**: a Sandbox menu next to the mode.
- **Remote**: the same override in `ChoiceRows` and in the chat prompt bar. Runtime defaults are Mac Settings only, per the wireframe.
- **Conversation header**: shows Sandbox On / Off / Runtime controlled / Unavailable on both apps before the first command (FR-010).
- **Servers**: the Mac pushes the defaults like `clientPermissions`. Each server computes its own capability (a spec edge case).

## Requirement coverage

| Requirement | Where |
|---|---|
| FR-001, FR-014 | SandboxCatalog, capability, SandboxDefaultRow, capsule |
| FR-002, FR-008, FR-013 | Capability gate and probes (R9); Antigravity Unavailable (R8) |
| FR-003, FR-003c, SC-006 | Missing file ⇒ As configured; no flag or env added |
| FR-003a, FR-003b | `SandboxSettings.defaults`, `Agent.sandboxOverride`, `agents/setSandbox` with nil to clear |
| FR-004, FR-005, FR-005a–c | Separate menu; Codex coupling |
| FR-006, FR-007, FR-007a | Failure classification, card, `continueWithoutSandbox` |
| FR-009, SC-007 | The launch layer only appends runtime args and env; scope and policy code unchanged; quickstart check |
| FR-010 | `effectiveSandbox` after the handshake; header capsule on Mac and Remote |
| FR-011 | Daemon-side resolution; server push; helper cap (amended) |
| FR-012 | Resolution at spawn; `releaseRuntime` every turn |

## Complexity Tracking

- No new service or dependency.
- It reuses:
  - StoreCoding persistence
  - the `clientPermissions` RPC and push pattern
  - the `LentEnvironment` TaskLocal pattern
  - `ModeLooseness`
  - the `SwitchNote`/`ChatActions` card pattern
  - the Pool resend path
- The one new mechanism is the per-host probe. It is needed because the flags parsing is not proof that ACP honours them.
