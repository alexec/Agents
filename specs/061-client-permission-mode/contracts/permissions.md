# Client permission contracts

## Settings RPC (control connections only)

- `clientPermissions/state`: no arguments; returns `{"cursor":"default","grok":"default"}`.
- `clientPermissions/set`: accepts both typed fields; validates enum values, atomically saves before applying; returns saved settings. Values are `default` and `alwaysApprove`.
- `clientPermissions/changed`: notification carrying saved settings.
- Agent/device/stranger roles cannot read or change these methods.

## Settings UI

Cursor and Grok each have a labelled permission-mode picker beside their runtime row, present even if unavailable. Choices are Default and Always-approve with one-line descriptions. No prompt or Remote controls.

## Approval contract

Under Always-approve, any permission request that offers allow-once (preferred) or only allow-always is answered before a pending card, attention event, permission notification or asked-permission workflow event is created. Ordinary tool progress remains visible. A request with no allow option uses the same card/phone delivery path as Default. Other runtimes retain existing behavior.

Default shows all permission requests from these runtimes.

## Host contract

The Mac is the source of truth. Settings are copied to each connected daemon on change and reconnect. Offline synchronization errors must be surfaced or retried, not represented as successful application.
