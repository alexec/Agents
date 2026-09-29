# Research: Client permission mode

## Decisions

1. **Daemon-owned independent settings.** Reuse atomic StoreCoding persistence and control-only RPC methods. AppModel propagates the Mac values to servers, following its existing retention/pool pattern. Classification must run on the owning host for correct symlink checks. A UI-only preference cannot affect unattended daemon requests.
2. **Grok process-scoped override, verified 2026-09-27.** `grok --permission-mode default agent --no-leader stdio` initialized and asked before a scratch file write despite the user's saved `permission_mode="always-approve"`. No user config was changed. Use `--permission-mode default` before `agent stdio` in RuntimeCatalog. The existing GROK_CONFIG_PATH overlay rejects permission keys; GROK_DEFAULT_SELECTED_PERMISSION only selects a menu row. Neither is a mode override.
3. **Preserve ACP metadata before trimming.** Current permission parsing discards name, locations and content. Grok's measured write request has kind edit, rawInput `{variant:"Write",file_path:...,content:...}`, and `_meta["x.ai/tool"].name="write"`. Cursor edit updates have kind edit, rawInput.path and no name. Parse explicit top-level/vendor tool names, paths and diffs before trimming raw metadata.
4. **Always-approve replaces the classifier.** The reach-based Auto-review classifier still asked for too many ordinary turns. Always-approve answers every permission request that offers allow-once (preferred) or only allow-always. Stored `autoReview` migrates on load. Questions that are not permission still wait.
5. **One-time decisions only.** Prefer allow_once; choose allow_always only when allow_once is absent. Existing pending cards remain untouched. Other runtimes keep their behavior.
6. **Existing Cursor grants remain.** A live scratch Cursor edit ran without a request; the client can only review requests the runtime sends. The spec explicitly preserves user-granted remembered approvals. Do not rewrite the person's Cursor config. Validate client-side decisions with ACP fixtures as well as live requests.

## Alternatives considered

- Runtime-native auto-review: Cursor now advertises a native flag, but it does not establish the same shared app policy or apply to Grok. Not used.
- Client-side reach classifier (Auto-review): shipped first, then replaced because ordinary turns still interrupted too often.
- Automatic allow-always when allow-once is also offered: breaks switching back to Default, so rejected; allow-always is only used when it is the sole allow option.

All design unknowns are resolved. Runtime-specific live validation limitations are reported separately from deterministic client-policy coverage.
