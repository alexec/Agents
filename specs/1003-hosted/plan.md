# Implementation Plan: Hosted T10, many organisations on one service

**Branch**: `agents/hosted-spec-1003` (spec only) | **Date**: 2026-10-22 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/1003-hosted/spec.md` (#2223).

## Summary

Everything is built in `agents-hosted`, around each account's control plane, which stays unchanged. Sign-up gains a gate in `/signin/callback`: block, rates, the account's age, the allowlist or an invite, and the cap, in that order, with a waitlist for the rest. A suspended account is a state on its record; the idle sweep also stops suspended copies. Plans are a table in the service. The limits are enforced in three places the service already owns: a store wrapper around each account's prefix (machines, clients, storage), the reverse proxy (connections), and the sweep (events kept). Billing is a small package behind an interface, with a fake Stripe in the tests. Operations are a deploy script, a disk snapshot, `/metrics`, the admin command and the runbook.

## Technical Context

**Language/Version**: Go 1.24 (`agents-hosted`). Shell (`deploy/gcp/hosted-up.sh`). HTML templates in `pages.go`. No Swift and no `Web/src` change is expected (see Clients).

**Primary Dependencies**: none new. Stripe is called over HTTPS with `net/http` and form bodies (no SDK). The webhook signature is HMAC-SHA256, checked with `crypto/hmac`.

**Storage**: the service's store, under `hosted/v1/` (see the spec's Key Entities), and each account's prefix `accounts/<id>/v1/…`, unchanged.

**Testing**: `cd Go && go test ./internal/hosted/... ./cmd/agents-hosted/...`, with the fake GitHub (now with `created_at`) and a fake Stripe in `hosted_test.go`, a fake clock, and the memory store. `shellcheck` and a dry run with no `gcloud` for `hosted-up.sh`.

**Target Platform**: Linux (the service's VM, in Docker), current browsers.

**Constraints**:

- **No control-plane change in 0.12.** 0.11 holds `control-plane` and `Go/` outside `Go/internal/hosted` and `Go/cmd/agents-hosted`. A gap that needs the control plane goes on the follow-up list (agents running at once; any limit refusal whose words the control plane does not pass on).
- **Ship without accounts.** No Stripe, Cloudflare, GitHub App or GCP account is made by an agent. Alex's steps are on #2227.
- **Bound data.** Every list the service keeps is bounded: the waitlist (by the rates and a cap of 10 000 entries), the invites (expired ones swept), the Stripe events (30 days), the rates (in memory, per hour).

**Scale/Scope**: one VM, one process, up to a few hundred accounts and 50 copies running at once.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec, decisions, plan and tasks come first, on #2223. |
| II. Capability-driven runtimes | Nothing changes for runtimes. |
| III. Scoped access and user control | Each account stays in its own prefix with its own key. The admin command runs only on the service's machine. A person can always read why they are refused and delete their account. |
| IV. Work must be inspectable | Every refusal says what it is, which limit and which plan. The log and `/metrics` count each kind. |
| V. Docs and quality travel with the feature | Each slice updates the how-to; tests come first in each slice. |

## Design

### Sign-up gate (#2152) — `Go/internal/hosted/signup.go`

`callback` gets the GitHub user (now with `created_at`). For a user with an account, nothing changes (sign-in is never limited). For a new user, `gate` decides, in order:

1. **Blocked** (`hosted/v1/blocked/<id>.json`): "not open to this account", nothing kept.
2. **Rates** (in memory, `rate.go`: a sliding hour per address from `clientOf`, and one in total): "Too many sign-ups".
3. **Already on the waitlist:** show the place again (not counted).
4. **Mode** `closed`: "Sign-up is not open yet."
5. **Allowed?** `open`; or `invite` with the login on the allowlist, or an unused, unexpired invite from the state cookie (the `invite` query is carried through `/signin` in the state cookie).
6. **Age:** younger than the minimum and not on the allowlist → waitlist (why: age).
7. **Cap:** the number of accounts (a `List` of `hosted/v1/accounts/`, cached for a minute) at the cap → waitlist at the front (why: cap).
8. Otherwise the account is made; the invite is spent with a conditional write first, so two people cannot use it.

The waitlist entry is written with `store.Absent`, so two tabs make one. The place is the entry's rank by time among the entries (a `List`, cached for a minute).

### Suspension and blocks — `accounts.go`, `copies.go`

`Account` gains `Plan`, `Suspended *Suspension{Reason, At}`, `Certificate time.Time`, `Stripe *StripeIDs`. `toAccount` refuses a suspended account with `403` before starting a copy. `inUse` cannot read the record on each request, so the minute sweep re-reads each running copy's record and stops a suspended one (FR-009's one minute). `tlsAllowed` still allows a suspended account's name.

### Copies and certificates — `copies.go`, `hosted.go`

`copyFor` checks the number running against `MaxCopies` before it starts one, and stops the copy with `open == 0` and the oldest `last`; with none, `errFull` → `503`. `tlsAllowed` keeps a sliding window of names allowed this hour and week, filled at start from the accounts' `Certificate` times, and writes `Certificate` on the account the first time.

### Admin command — `Go/cmd/agents-hosted/admin.go`, `Go/internal/hosted/admin.go`

`agents-hosted admin <verb> …` opens the store from the same environment as `serve` and calls exported functions in `hosted` (`Admin{Store, Now}`), so the tests drive the same code. It prints plain lines. It needs no keeper except for `backup` and `restore`, which copy sealed bytes as they are.

### Plans and limits (#2224) — `plans.go`, `limited.go`

- `plans.go`: `type Plan struct{ Name string; Machines, Clients, Connections int; StorageBytes int64; EventsKept time.Duration; AgentsRunning int }` and `var plans = map[string]Plan{"free": …, "pro": …}`.
- `limited.go`: `limitedStore` wraps the account's `*store.Prefixed`:
  - `Put` of a key under `v1/machines/` or `v1/clients/` with `store.Absent` (a new record) lists that folder and refuses at the limit with `*LimitError`.
  - It keeps the account's bytes in memory: counted once when the copy starts (a `List` and the sizes; a store that can say a size without reading, the folder store, says it), then kept up to date on each `Put` and `Delete` (it reads the old size before a rewrite). A `Put` that makes the total larger than the plan's storage is refused.
  - `LimitError.Error()` is the refusal's words (FR-022).
- The plan is read when the copy starts, and again by the minute sweep, so a webhook's change reaches a running copy within a minute.
- The proxy counts WebSocket upgrades per account (`Upgrade: websocket`) in `copyRunning`, and answers `429` with the words over the limit.
- The hourly sweep lists `v1/events/` in each account's prefix and deletes keys older than the plan keeps, by the time in the key or the record.
- Workspace providers stay off: `ProviderHome` is not set (as today); a test checks it.

**Does the control plane pass a store error's words on?** The slice checks each path (host join, client pairing, a record write) in a test. Where the words do not reach the client, the refusal still holds, the words go to the log and `/metrics`, and the path goes on the control-plane follow-up list for after v0.11.0.

### Billing (#2225) — `Go/internal/hosted/billing/`

```go
type Stripe interface {
    Checkout(ctx context.Context, account, customer string) (url string, err error)
    Portal(ctx context.Context, customer string) (url string, err error)
}
func Verify(payload []byte, header, secret string, now time.Time) (Event, error)
```

`stripeHTTP` calls `POST /v1/checkout/sessions` and `POST /v1/billing_portal/sessions` with the secret key. `Verify` checks `t=…,v1=…` by HMAC-SHA256 within 5 minutes. The service routes `/account/upgrade`, `/account/billing` and `/billing/webhook` only when billing is on. The fake Stripe in the tests is an `httptest.Server` and a signer.

### Operations (#2226)

- `deploy/gcp/hosted-up.sh`: modelled on `up.sh`, with its own names (`AGENTS_HOSTED_*`), the compose file and a daily snapshot schedule (as #2136). `--check` lists what is missing and exits.
- `/metrics` on a second listener, `AGENTS_HOSTED_METRICS_PORT` (default 9795), not published by compose: plain Prometheus text written by hand (no new dependency).
- `admin backup` / `admin restore`: one account's prefix to and from a folder of files, as #2137's backup does for a control plane.

## Slices

Each slice is one lane and one PR, stacked, with `hold:v0.11`. Areas: `hosted` for 1–3, `billing` for 4, `hosted-ops` for 5.

1. **Sign-up protection** (#2152): gate, waitlist, invites, allowlist, age, rates, cap, copies limit, certificate cap, suspension, block, the admin command, the pages.
2. **Plans and limits** (#2224): `plans.go`, `limitedStore`, connections, events sweep, the account page's plan and use, the apart test.
3. **Clients check**: walk the Mac, the Remote and the web page against a suspended account and an account at a limit on a scratch set-up; file what does not show the words.
4. **Billing** (#2225).
5. **Operations** (#2226).
6. **After v0.11.0 ships** (control-plane follow-ups): agents running at once; the words of any limit refusal the control plane does not pass on.
