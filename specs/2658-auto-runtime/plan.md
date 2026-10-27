# Implementation Plan: Auto Runtime

**Branch**: `agents/2658-auto-runtime-the-app-picks` | **Date**: 2026-10-27 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/2658-auto-runtime/spec.md` (approved by Alex,
2026-10-27, with **Plan** in place of **Read-only**).

## Summary

The daemon (Go agentsd) gets a mapping table: for each runtime, each value of Model, Permission
mode, Permission requests and Sandbox gives that runtime's own setting. The table ships in the
daemon and the person's overrides live beside `sandbox.json`. A start request can name
`runtimeID: "auto"` and the values; the daemon picks the runtime from the person's order and the
runtimes' state, maps the values to native config option values, and records both on the agent.
The three clients show the new words on every runtime, Auto in the chooser, **Auto · <runtime>**
in the header and an Auto page in Settings. They ask the daemon for the mappings; they do not
map by themselves.

## Technical Context

**Language/Version**: Go (agentsd), Swift 6 (App, Remote, Shared/UI, AgentsKit), TypeScript
(Web).

**Primary Dependencies**: none new. The wire types come from `Packages/Wire` (`scripts/wire.sh
gen`).

**Storage**: `<SettingsDir>/auto.json` (the person's order, Include switches and overrides),
beside `sandbox.json` and `client-permissions.json`. The Mac writes it to each machine as it does
`sandbox/set` today (`App/Sources/AppModel.swift:2289–2296`). The shipped default table is Go
code, not a file.

**Testing**: `go test ./Go/internal/agentsd/...` for resolution and mapping; AgentsKit unit tests
and `Fixtures/web/` fixtures for the words, shared by Swift and Web tests; run-app walks for the
Mac, the Remote (simulator build) and the web page.

**Target Platform**: macOS app, iOS/iPadOS Remote, web page; agentsd on macOS and Linux servers.

**Project Type**: desktop + mobile + web clients over one daemon.

**Performance Goals**: Auto resolution adds no ACP round trip at start: it reads the runtime state
and the option cache (`options.go` `runtimeOffers`) that the daemon already has.

**Constraints**: the runtime never changes in a session; no value gives more access than its
words say (SC-005); an organisation policy (#998) still caps the result.

**Scale/Scope**: 8 runtimes × 14 values; 4 tables; 3 clients; ~7 PRs.

## Constitution Check

| Principle | How this plan meets it |
| --- | --- |
| I. Spec-led | Spec approved 2026-10-27; this plan and `tasks.md` follow. |
| II. Capability-driven | The table is keyed by runtime id, as `sandboxCatalog` is today, but each cell is checked against the options the runtime **advertises** (`runtimeOffers`). A cell whose native value the runtime does not offer is skipped, not sent. |
| III. Scoped access | "Nearest safer" never maps to more access. A person's override can, by their own choice (FR-016). Organisation policy and the helper sandbox rule still apply after mapping. |
| IV. Inspectable | The agent records Auto, the runtime picked and every native value given (FR-007); the header and the menus say them. |
| V. Docs | The spec's Docs list is a task in the last part. |

No deviation.

## Design

### Wire (Packages/Wire)

Wire values stay where they exist; only their words change:

- `SandboxChoice` stays `runtime | on | off`; the words become **Default sandbox**, **Runtime
  sandbox**, **No sandbox**.
- `ClientPermissionMode` stays `default | alwaysApprove`; the words become **Request cards**,
  **Yes to all**.

New:

- `ModelLevel`: `fast | balanced | smart`.
- `PermissionLevel`: `plan | ask | approveForMe`.
- `StartRequest.levels?: Levels` with `model?`, `permission?`, `permissionRequests?:
  ClientPermissionMode`. `runtimeID` may be `"auto"`.
- `Agent.auto?: AutoPick` — `runtimeID` picked, the levels asked for, the native values given,
  and why each runtime before it was skipped.
- `AutoSettings`: `order: [runtimeID]`, `excluded: [runtimeID]`, `overrides: {field: {runtimeID:
  {level: NativeSetting}}}`, `setBy`.
- `AutoMapping`: one cell — `native`, `mark: autoMapped | nearestSafer | yours | notPossible |
  dropped`, `note`.
- Methods: `auto/state`, `auto/set`, `auto/changed` (as `sandbox/*`); `auto/mappings` (every
  cell, with marks, for the Settings tables and the pill menus); `auto/preview` (for levels and a
  folder: the runtime Auto would pick now, or why none can).

See [contracts/auto.md](contracts/auto.md).

### Daemon (Go/internal/agentsd)

- `automap.go`: the shipped table (`autoDefaults`), `autoCell(runtime, field, level)` with the
  person's override, and the check against `runtimeOffers(runtimeID)`.
- `autopick.go`: `pickRuntime(levels, cwd)` — order, Include, `RuntimeAvailability`, out
  (`allowances.go isOutState`), rate limited last, every level possible; returns the pick or a
  reason per runtime.
- `turns.go startFor`: when `RuntimeID == "auto"`, pick first; then, for any runtime, fold
  `levels` into `StartOptions.Values` (model, mode, effort), the sandbox override and the
  per-agent client permission, before today's code runs. Native `StartOptions.Values` win over a
  level (the ⋯ own menu).
- Per-agent Permission requests: `Agent.clientPermission`, read by `alwaysApproves` before the
  Mac-wide value in `client-permissions.json`.
- Workflows and personas (`settings.go workflowSettings`, `workflowruns.go runAgent`) and
  `start_session` (`helperstart.go`) accept `auto` and the level words, and send them as
  `levels`. `runtime: auto` with a native value is refused (spec, Story 5).
- Effort is passed for the first time by `runAgent` and `helperRequest` (today only parsed).

### Clients

- AgentsKit: `LevelWords` (the words in the spec) replaces `SandboxWords.choice/override` and the
  `ClientPermissionCapsule` words; fixture `Fixtures/web/levels/words.json` shared with Web.
- Mac (`App/Sources/Chat/PromptBar.swift`, `Shared/UI/Chat`): Auto first in the runtime
  `SelectCapsule`; level pills (`LevelPill`) in place of `OptionMenu` mode and `ModelPill`; the
  runtime's own options behind **⋯ <runtime>'s own**; header `Auto · <runtime>`; Settings ▸
  Agent Runtimes ▸ Auto (`AutoSettingsView`).
- Remote (`StartAgent/ChoiceRows.swift`): Runtime row with Auto, Model segmented control,
  Permission mode and Sandbox rows; Settings Auto page.
- Web (`views/NewAgent.tsx`, `views/PromptMenus.tsx`, `model/sandbox.ts`): the same; the Auto
  page is new in Settings.

## Delivery: one PR per part, in order

Each part is its own issue and agent (AGENTS.md #2504), after the one before has auto-merge on.

1. **Words and wire** — schema, generated code, `LevelWords` + fixture; the new words on every
   runtime for sandbox and permission requests (all three clients). No Auto yet.
2. **Daemon: levels and Auto** — table, overrides file, `auto/*` methods, pick, start, workflows,
   personas, `start_session`, per-agent permission requests, effort.
3. **Mac: Auto and level pills** — chooser, pills, ⋯ own, header.
4. **Mac: Settings ▸ Auto** — order, Include, mapping tables.
5. **Remote** — form, chat, Settings.
6. **Web** — form, chat, Settings.
7. **Checks and docs** — nightly check marks dropped cells; **Continue on <runtime>** on an out
   Auto session; Auto as the default for a new install; the docs list in the spec.

## Project Structure

```text
specs/2658-auto-runtime/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/auto.md
└── tasks.md
```
