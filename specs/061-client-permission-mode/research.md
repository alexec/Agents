# Research: Client permission mode

## Decisions

1. **Daemon-owned independent settings.** Reuse atomic StoreCoding persistence and control-only RPC methods. AppModel propagates the Mac values to servers, following its existing retention/pool pattern. Classification must run on the owning host for correct symlink checks. A UI-only preference cannot affect unattended daemon requests.
2. **Grok process-scoped override, verified 2026-09-27.** `grok --permission-mode default agent --no-leader stdio` initialized and asked before a scratch file write despite the user's saved `permission_mode="always-approve"`. No user config was changed. Use `--permission-mode default` before `agent stdio` in RuntimeCatalog. The existing GROK_CONFIG_PATH overlay rejects permission keys; GROK_DEFAULT_SELECTED_PERMISSION only selects a menu row. Neither is a mode override.
3. **Preserve ACP metadata before trimming.** Current permission parsing discards name, locations and content. Grok's measured write request has kind edit, rawInput `{variant:"Write",file_path:...,content:...}`, and `_meta["x.ai/tool"].name="write"`. Cursor edit updates have kind edit, rawInput.path and no name. Parse explicit top-level/vendor tool names, paths and diffs before trimming raw metadata.
4. **Conservative shared classifier.** Use FolderScope with current cwd plus initial additionalDirectories. Recognize file action kinds and known names, but refuse unknown named tools even if they claim a safe kind. Restrict shell commands to ordinary project operations and validate their arguments. Unknown shell syntax and tools ask. No title-based command inference.
5. **One-time decisions only.** Require allow_once; never choose allow_always for automatic review. Override existing blanket app-tool permission handling only for Cursor/Grok. Existing pending cards remain untouched. Other runtimes keep their behavior.
6. **Existing Cursor grants remain.** A live scratch Cursor edit ran without a request; the client can only review requests the runtime sends. The spec explicitly preserves user-granted remembered approvals. Do not rewrite the person's Cursor config. Validate client-side decisions with ACP fixtures as well as live requests.

## Alternatives considered

- Runtime-native auto-review: Cursor now advertises a native flag, but it does not establish the same shared app policy or apply to Grok. Not used.
- General shell interpretation or a second model: unnecessary complexity, latency and uncertain boundaries. Unknown requests remain human-reviewed.
- Automatic allow-always: breaks switching back to Default, so rejected.

All design unknowns are resolved. Runtime-specific live validation limitations are reported separately from deterministic client-policy coverage.
