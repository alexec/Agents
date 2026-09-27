# Data model: Client permission mode

## ClientPermissionMode

Codable string enum: exactly `default` and `autoReview`. No full-access value.

## ClientPermissionSettings

Two fields: `cursor` and `grok`, each defaulting to `default`. Unsupported runtime IDs never qualify for this review policy. Persist to `client-permissions.json` under the daemon root. Missing or corrupt data must fail closed to Default.

## Permission review

Input: ToolCall, agent.cwd, agent.folderScope, and current runtime setting. Output: eligible for one-time approval, or ask. Approval requires an offered `allow_once` option. No approval cache is created.

Validate every known target path, working directory and path-bearing argument. Follow symlinks through FolderScope on the owning host. Unknown metadata, ambiguous action, shell control syntax, publishing and privilege escalation ask.

## Transitions

Saving settings changes subsequent requests only. Pending cards and the user's existing runtime-owned remembered grants remain untouched. Setting one runtime leaves the other unchanged. Server reconnect copies the Mac value before subsequent starts.

