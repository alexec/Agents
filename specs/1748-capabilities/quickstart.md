# Quickstart: check capabilities (#1748)

1. **Schema.** Lease "build". `scripts/wire.sh check` passes. Remove one `x-capability` line;
   it fails and names the method. Put it back.
2. **Swift.** `scripts/build-cache.sh swift test --package-path Packages/AgentsKit --filter WireSchemaTests`
   passes: each method Swift calls has a capability in the generated table.
3. **Go lists.** `Go/scripts/go.sh test ./internal/agentsd/ ./internal/controlplane/` passes: the
   host's list is what its handlers make; a host without a required capability is `needsUpdate`;
   a client without one gets `-32008` with `missing`.
4. **Clients.** On a scratch set-up (run-app skill), connect a host whose list has no
   `chat.branch/1` (the test flag `AGENTS_TEST_DROP_CAPABILITIES=chat.branch/1` on the scratch
   `agentsd`). "Branch from Here" is disabled with the update text on the Mac, the Remote and the
   web page. Settings shows each version.
5. **Versions.** `scripts/version.sh` on a tag prints `X.Y.Z`; after it, `X.Y.(Z+1)-dev.N+g<sha>`.
