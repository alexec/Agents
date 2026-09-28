# Data model: Client permission mode

## ClientPermissionMode

Codable string enum: exactly `default` and `alwaysApprove`. No classifier value. A stored `autoReview` (the earlier smart-review name) decodes as `alwaysApprove`.

## ClientPermissionSettings

Two fields: `cursor` and `grok`, each defaulting to `default`. Unsupported runtime IDs never qualify for this policy. Persist to `client-permissions.json` under the daemon root. Missing or corrupt data must fail closed to Default.

## Permission decision

Input: the permission request's options and the runtime's current setting. Output: answer with allow-once (preferred) or allow-always when Always-approve and either is offered; otherwise ask. No approval cache is created. Pending cards already on screen are never reconsidered.

## Transitions

Saving settings changes subsequent requests only. Pending cards and the user's existing runtime-owned remembered grants remain untouched. Setting one runtime leaves the other unchanged. Server reconnect copies the Mac value before subsequent starts.
