# Validate feature 061

1. Run `swift test --package-path Packages/AgentsKit --filter ClientPermission` for persistence and daemon request behavior.
2. Run the existing permission, ACP and tool policy suites; run `scripts/docs.sh check`.
3. Use the run-app skill to build and launch a scratch root. Read clientPermissions/state: both fields are default. Save Cursor alwaysApprove and leave Grok default; restart the scratch daemon and verify persistence. Write a legacy `{"cursor":"autoReview","grok":"autoReview"}` file and confirm both load as alwaysApprove.
4. In Settings ▸ Agent Runtimes inspect both controls, descriptions and unavailable runtime rows.
5. Exercise each runtime with an in-project edit, an out-of-reach path, git push and sudo under Always-approve: all must proceed without permission cards or notifications. Under Default, the same actions wait.
6. Change a setting while a card is pending: it stays. Answer it, then make a new request and verify the new setting. Verify allow_once is used and no remembered grant was created.
7. Check question cards and Grok questions in words under Always-approve (they still wait), and that other runtimes are unchanged.
8. Use the test-servers skill or its fake SSH fixture to verify Mac settings propagation on change/reconnect.
9. Stop all scratch processes and remove scratch roots. Record commands, results and any unavailable live-runtime checks in this file after validation.
