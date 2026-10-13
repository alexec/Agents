# Quickstart: walk Write It for Me

On a scratch set-up (run-app skill), never the real control plane. The steps need the default
runtime signed in on this Mac.

1. Build the test MCP server of #691 with renamed tools (`TEST_PROVIDER_RENAMED=1`: its tools
   are `machines-get`, `machine-on`, `machine-off`). Start the scratch app.
2. Settings ▸ Control plane ▸ Providers ▸ Add Provider… ▸ MCP server. Type its command. Add a
   secret `TEST_TOKEN` = `s3cret-value-858`.
3. Press **Write It for Me**. See the step line (L10b). Open Details….
4. See the draft fill the Tool map field and "✓ Listed 2: …" (L10d). Press **Add**. See the card
   list the two workspaces, and the record's `writtenBy`.
5. Search the scratch root for `s3cret-value-858`: it must be only in `provider-secrets.json`
   (SC-003).
6. Remove the provider. Add it again with `TEST_PROVIDER_ASK_START=1`, which makes the stand-in
   prompt ask the agent to prove a start. See the question (L10c). Press Don't: the server's
   call log shows no `machine-on`. Write Again, press Start It: one `machine-on`.
7. Your commands: put `Packages/ControlPlane/Tests/Fixtures/cws` on the scratch PATH. CLI `cws`,
   Write It for Me. See `ran cws --help`, the Config editor, and "✓ Listed 2".
8. Press Start on a card of the added provider. In the log, no agent is started (SC-005).
