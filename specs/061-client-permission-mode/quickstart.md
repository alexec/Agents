# Validate feature 061

1. Run `swift test --package-path Packages/AgentsKit --filter ClientPermission` for policy, persistence and daemon request behavior.
2. Run the existing permission, ACP and tool policy suites; run `scripts/docs.sh check`.
3. Use the run-app skill to build and launch a scratch root. Read clientPermissions/state: both fields are default. Save Cursor autoReview and leave Grok default; restart the scratch daemon and verify persistence.
4. In Settings ▸ Agent Runtimes inspect both controls, descriptions and unavailable runtime rows.
5. Exercise each runtime with an in-project edit and test command, then an out-of-reach path, git push and sudo. Approved actions must remain in the transcript without permission notifications; risky actions must remain pending.
6. Change a setting while a card is pending: it stays. Answer it, then make a new request and verify the new setting. Verify allow_once is used and no remembered grant was created.
7. Check worktree and extra-folder requests, symlink escapes, compound shell commands, unknown tools, workflow/start-agent/lease tools, question cards and other runtimes.
8. Use the test-servers skill or its fake SSH fixture to verify Mac settings propagation on change/reconnect; review scope on the host.
9. Stop all scratch processes and remove scratch roots. Record commands, results and any unavailable live-runtime checks in this file after validation.

