# Session failures (052)

Each `*.json` except the rate-limit ones is the `_meta` a runtime puts on a `session/prompt`
result, or on a `session_info_update`, when it reports a typed failure through JetBrains' AIR
session-failure extension. The shapes and the category/actions pairs are copied from the policy
table in `@agentclientprotocol/claude-agent-acp` 0.81.2 (`dist/session-failure-extension.js`),
which `@agentclientprotocol/codex-acp` 1.13.1 copies. The titles are the adapters' fallback
titles, except `quota-exhausted`, which is the Claude SDK's own usage-limit wording.

`claude-rate-limit-*.json` are the `_meta` on a Claude `usage_update`: the SDK's
`SDKRateLimitInfo` under `_claude/rateLimit` (claude-agent-sdk, `sdk.d.ts`).
