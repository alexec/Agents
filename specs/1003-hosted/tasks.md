# Tasks: Hosted T10, many organisations on one service

**Input**: `spec.md` and `plan.md` in `specs/1003-hosted/`.

**Tests**: the spec asks for automated checks (SC-001 to SC-008), so each slice has test tasks. Write them first. They use the fakes in `Go/internal/hosted/hosted_test.go` (GitHub, and Stripe from slice 4), a fake clock and the memory store.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files).

**Not before v0.11.0 ships.** Nothing here merges to `main` until then (`hold:v0.11`). Each phase is one stacked PR.

## Phase 1: Sign-up protection (#2152; area hosted)

**Goal**: only invited or allowed people get accounts; everyone else waits; nothing can use up the service; the operator can suspend and block. Covers US1–US4.

### Tests first

- [ ] T001 [US1] Fake GitHub gives `created_at`; tests for an invite link (made by `Admin.Invite`), used once, expired, and an allowlist login, in `Go/internal/hosted/signup_test.go`.
- [ ] T002 [P] [US2] Tests: no invite → waitlist once with its place; cap full → waitlist at the front, invite not spent; young account → waitlist with why; blocked id → nothing kept; `admit` then sign in → account.
- [ ] T003 [P] [US3] Tests with a fake clock: 3 per address and 30 in total per hour; a sign-in to an existing account is never limited (SC-002).
- [ ] T004 [P] [US3] Tests: `MaxCopies` stops the copy idle longest, `503` when none is idle; `/v1/tls-allowed` says no past 10 an hour and 40 a week, and a name already allowed is not new.
- [ ] T005 [P] [US4] Tests: suspend a running account with `Admin.Suspend`; within one sweep its address answers `403` with `Agents-Refusal: suspended`; the account page says why; `unsuspend` starts it again; `block` suspends and refuses sign-in (SC-003).

### Build

- [ ] T006 [US1] `Account` gains `Plan`, `Suspended`, `Certificate`; `GitHubID` gains `Created`; `gitHub.user` reads `created_at`, in `accounts.go` and `github.go`.
- [ ] T007 [US1] `signup.go`: the gate of plan.md, the allowlist, invites (spent with a conditional write), the waitlist, blocks; `rate.go`: the sliding-hour rates. `Config` gains `SignUp`, `MaxAccounts`, `MinGitHubAge`, `SignUpsPerAddress`, `SignUpsPerHour`, `MaxCopies`, `CertsPerHour`, `CertsPerWeek`.
- [ ] T008 [US1] `/` and `/signin` carry `?invite=` through the state cookie; the pages show the waitlist, rate, invite, blocked and suspended lines (FR-011).
- [ ] T009 [US3] `copies.go`: `MaxCopies`; `hosted.go`: the certificate cap and `Certificate` on the account.
- [ ] T010 [US4] `toAccount` refuses a suspended account; the minute sweep re-reads running copies' accounts and stops a suspended one.
- [ ] T011 [US4] `admin.go` (`Admin`: invite, allow, disallow, waitlist, admit, suspend, unsuspend, block, unblock, accounts, plan) and `Go/cmd/agents-hosted/admin.go` (`agents-hosted admin …`), and the settings from the environment in `main.go`.
- [ ] T012 Clients: check what the Mac and the Remote show for a `403` at the control plane's address; record `same` or the parity issue in the commit (CL-003).
- [ ] T013 Docs: the settings and the admin command in `docs/how-to/run-the-hosted-service.md`.

**Checkpoint**: `go test ./internal/hosted/... ./cmd/agents-hosted/...` passes.

## Phase 2: Plans and per-organisation limits (#2224; area hosted)

**Goal**: each account is held to its plan, with words that say so, and nothing is deleted. Covers US5.

### Tests first

- [ ] T020 [US5] Tests: machines and clients over the Free limit refused with the words; a rewrite of an existing record is not refused, in `Go/internal/hosted/limits_test.go`.
- [ ] T021 [P] [US5] Tests: storage: a write past 1 GB (a small limit in the test) refused, a smaller rewrite and a delete allowed; the count survives a copy restart.
- [ ] T022 [P] [US5] Tests: connections over the limit get `429` with the words; events past 7 days deleted by the sweep, newer kept.
- [ ] T023 [P] [US5] Test: two accounts, each with a policy, machines and a secret: neither copy reads or changes the other's (SC-005); providers are off.
- [ ] T024 [P] [US5] Test: which paths pass the words to the client (a machine join, a client pairing); record the rest for phase 6.

### Build

- [ ] T025 [US5] `plans.go`: the table of FR-020.
- [ ] T026 [US5] `limited.go`: `limitedStore` and `LimitError`; `startCopy` wraps the account's store with it.
- [ ] T027 [US5] Connections: the count in the proxy; the plan read again by the minute sweep.
- [ ] T028 [US5] The hourly events sweep.
- [ ] T029 [US5] The account page shows the plan and the use of each limit (FR-024).
- [ ] T030 Docs: plans and limits in `docs/how-to/run-the-hosted-service.md`.

## Phase 3: Clients check (area hosted; no code expected)

- [ ] T040 Walk a scratch hosted service with the Mac (run-app), the Remote (the walk simulator) and the web page: a suspended account, and an account at its machines limit. Each shows the words, or an issue is filed and the parity table updated.

## Phase 4: Billing (#2225; area billing)

- [x] T050 [US6] Tests with a fake Stripe: no key → no routes, no **Upgrade** (SC-006); Upgrade → Checkout with `client_reference_id`; webhook: bad signature refused, old one refused, each event acted on once (SC-007); deleted subscription → Free, nothing deleted; Manage Billing → portal.
- [x] T051 [US6] `Go/internal/hosted/billing/`: `Stripe`, `stripeHTTP`, `Verify`.
- [x] T052 [US6] Routes and the account page's **Upgrade** and **Manage Billing**; the Stripe ids on the account.
- [x] T053 Docs: billing in the how-to; a Stripe row in `docs/reference/integrations.md`; Alex's steps on #2227.

## Phase 5: Operations (#2226; area hosted-ops, and hosted for the code)

- [x] T060 [US7] `deploy/gcp/hosted-up.sh` with `--check`; a test that it names each missing input (SC-008).
- [x] T061 [US7] The daily disk snapshot, as #2136.
- [x] T062 [US7] `/metrics` on its own listener, with a test.
- [x] T063 [US7] `admin backup` and `admin restore` of one account, with a test.
- [x] T064 [US7] The runbook (FR-044).

## Phase 6: After v0.11.0 ships (area control-plane)

- [ ] T070 Agents running at once: a control-plane hook that `agents-hosted` sets from the plan.
- [ ] T071 The words of each limit refusal that T024 found the control plane does not pass on.

## Dependencies

Phase 1 → Phase 2 → Phase 3. Phases 4 and 5 need Phase 2's account fields and can run beside Phase 3. Phase 6 waits for v0.11.0.
