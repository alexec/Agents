# Data Model: Auto Runtime

## Levels (new enums)

| Type | Values | Words |
| --- | --- | --- |
| `ModelLevel` | `fast`, `balanced`, `smart` | Fast, Balanced, Smart |
| `PermissionLevel` | `plan`, `ask`, `approveForMe` | Plan, Ask, Approve for me |
| `ClientPermissionMode` (exists) | `default`, `alwaysApprove` | Request cards, Yes to all |
| `SandboxChoice` (exists) | `runtime`, `on`, `off` | Default sandbox, Runtime sandbox, No sandbox |

In workflow and persona files: `fast | balanced | smart`; `plan | ask | approve-for-me`;
`request-cards | yes-to-all`; `default | runtime | none`.

## Levels (on a start request)

- `model?: ModelLevel`
- `permission?: PermissionLevel`
- `permissionRequests?: ClientPermissionMode`
- The sandbox stays `StartRequest.sandbox`.

Rule: a native value in `startOptions.values` for the same option wins over the level.

## NativeSetting

One cell's value on one runtime:

- `options?: {optionID: value}` — config option values (mode, model, effort).
- `sandbox?: SandboxChoice`
- `clientPermission?: ClientPermissionMode`

## AutoMapping (a cell)

- `runtimeID`, `field` (`model | permission | permissionRequests | sandbox`), `level`
- `native: NativeSetting?` (absent when not possible)
- `mark`: `autoMapped | nearestSafer | yours | notPossible | dropped`
- `note?`: one line, such as "nearest safer: no plan mode"

## AutoSettings (`<SettingsDir>/auto.json`)

- `order: [runtimeID]` — runtimes not in the list go last, in the shipped order.
- `excluded: [runtimeID]`
- `overrides: {field: {runtimeID: {level: NativeSetting}}}`
- `setBy?` — as `SandboxSettings`.

## AutoPick (on the Agent)

- `runtimeID` — the runtime picked.
- `levels` — as asked.
- `native: NativeSetting` — what was given.
- `skipped: [{runtimeID, reason}]` — why each runtime before it was not used.

## State

The runtime of an Auto agent never changes. A later level change on a running agent maps on the
same runtime and goes through `agents/setOption` (mode, model, effort), `sandbox` per-agent set,
or the per-agent client permission.
