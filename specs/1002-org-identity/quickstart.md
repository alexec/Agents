# Quickstart: prove T9 on a scratch set-up

No real tenant is needed. The fake OIDC provider and the SCIM fixtures are in the Go tests (research R7). Real tenants are Alex's account test, later (#1782).

1. **Org provider and ticket (slice 1).** Start a scratch control plane with two copies and a local keeper (`test-servers`), and the fake provider on loopback. As the admin, `signIn/orgProviders/set` with the fake issuer and secret. On a pairing connection, `signIn/orgStart`, follow the URL with the fake's auto-consent, take the ticket from the callback, and `signIn/ticket`. The connection is a client of the new person. Send the same ticket on a second connection: refused. Search the store for the secret: 0 finds.
2. **Domains (slice 1).** Claim `example.test` with the fake DNS answer, **Check**, turn on **Require this provider**. A Google test sign-in at `example.test` is refused with `orgSignInRequired`; the local owner pairs by a code as before.
3. **SCIM (slice 2a).** `scim/tokens/make`, then play `scim/testdata/okta-*.json` and `entra-*.json` against `/scim/v2/` with the token. People and Groups match the fixtures. Play the deactivation: the three clients of that person close with `suspended` within 5 s on both copies.
4. **Machines (slice 2b).** With a scratch root joined as that person and a fake runtime turn running, deactivate by SCIM: the turn stops, workflows pause, and every agent and file stays.
5. **Clients (slice 3).** `run-app`, the walk simulator and headless Chrome on the scratch control plane: the org button is first; the web page signs in with no code; a suspended client shows only its line.
6. **Console (slice 4).** Headless Chrome as an admin: Console ▸ Sign-In adds a provider, shows the redirect URI, claims a domain, makes a token, and marks a SCIM group **Gives the admin role**.
7. **Close everything** with the run-app skill's "When you are done" steps.
