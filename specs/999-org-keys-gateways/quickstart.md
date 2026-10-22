# Quickstart: check org keys and gateways end to end

How a build lane proves T6 on scratch set-ups. Close every scratch app when done (run-app "When you are done"). Hold the "build" lease for each build, test or scratch app.

## 1. Control plane and delivery (slice 1)

1. `test-servers` skill: a scratch control plane with two copies, two people (Priya admin, Sam), Sam's devbox machine and a scratch Mac host.
2. As Priya, by the wire: `orgRoutes/set` a `baseURL` route "Fake Gateway" to `https://127.0.0.1:<fake port>` with `apiKey: test-key-1234`, for Claude, everyone.
3. Expect: each of Sam's machines logs `host/orgRoutes` with one route within 5 s; `orgRoutes/mine` as Sam lists it; `orgRoutes/list` returns no value; the store holds no `test-key-1234` (grep the store folder).
4. Set the route's `groups` to a group without Sam: Sam's machines get an empty delivery.

## 2. The machine (slice 2)

1. Start a fake provider (Anthropic Messages shape, `scripts/fake-acp-runtime.py` neighbours) that logs the `x-api-key` it gets and answers with known `usage`.
2. Start a Claude session on the org account (`StartRequest.accountID = org:fake-gateway`).
3. Expect: the fake provider logs `test-key-1234`; `ps eww` of the runtime shows `ANTHROPIC_BASE_URL=https://127.0.0.1:…` and a stand-in, not the key; the leak search over the root, `~/.agents`, `daemon.log`, `events.jsonl` and the transcript finds 0; the turn's `relayTokens` equal the fake answer's usage.
4. Set T5 policy `runtimes.claude.reach: ["gateway"]`: a start on the Default account is refused with `policyRefused`.
5. Answer 429 with `retry-after: 60`: the org account is out for 60 s, the Default account is not.
6. Remove the route: the session stops with "Your organisation removed Fake Gateway.", and `<root>/org-routes/` is empty.

## 3. Clients (slice 3)

`run-app` window, the Remote walk simulator and headless Chrome, with the route of step 1: the account picker shows **Fake Gateway** with **From your organisation**; Runtimes shows **Organisation · No plan limit**; with the policy of step 2.4 the Default account is dimmed with **Set by your organisation**.

## 4. Console (slice 4)

Headless Chrome as Priya: Console ▸ Model Access ▸ Add Route for each kind (with fake values); the value field is empty after Save; the fingerprint shows; Replace Key raises the version; Remove asks first. Console ▸ Policy shows **Reaches the model by** per runtime and **Antigravity's terms**.

## 5. Real accounts (Alex, later, not a gate)

See the report on #999: one item per kind on Alex's 0.11 checklist.
