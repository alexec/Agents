# Contract: auto/* methods and start

All shapes go in `Packages/Wire/daemon.schema.json` and `daemon.openrpc.json`, then
`scripts/wire.sh gen`.

## agents/start (changed)

`StartRequest`:

- `runtimeID`: a runtime id, or `"auto"`.
- `levels?`: `{ model?: ModelLevel, permission?: PermissionLevel, permissionRequests?: ClientPermissionMode }`.

Errors (new): `autoNoRuntime` with `data.skipped: [{runtimeID, reason}]` when no included
runtime can take the session. The client keeps the prompt and shows the reasons.

## auto/state → AutoSettings

## auto/set (AutoSettings) → AutoSettings

Saves `<SettingsDir>/auto.json`; sends `auto/changed`.

## auto/changed (notification) → AutoSettings

## auto/mappings (Empty) → [AutoMapping]

Every cell for every known runtime. A cell's mark is `dropped` when its native value is not in
the runtime's advertised options.

## auto/preview ({ cwd, levels, sandbox? }) → { runtimeID?, native?, skipped }

The runtime Auto would pick now, for the chooser's subtitle ("Picks Claude now") and the pill
menus ("Balanced: Sonnet 5 on Claude").

## Agent (changed)

- `auto?: AutoPick`
- `clientPermission?: ClientPermissionMode` — per agent; absent follows Settings.

## Workflow and persona front matter (changed)

- `runtime: auto`
- `model:` a level word or a native value; `permission-mode:` a level word or a native value.
- `permission-requests: request-cards | yes-to-all` (new key).
- `sandbox: default | runtime | none` (new key).
- `runtime: auto` with a native `model:` or `permission-mode:` is refused.
