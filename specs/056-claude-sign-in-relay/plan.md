# Implementation Plan: Claude on Servers Through This Mac's Sign-in

**Branch**: `agents/claude-sign-in-relay` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/056-claude-sign-in-relay/spec.md`. Alex settled
D1–D2 and confirmed D3–D7 on 2026-09-26.

## Summary

A server's Claude stops taking a pasted token and signs in through the Mac, the way Codex has
since 047. The Mac's relay, TLS listener, certificates and the server's per-account gate
already exist. This feature makes them carry more than one runtime:
- the relay policy says where each runtime's sign-in comes from and how its runtime is
  pointed at the gate;
- the Mac's sign-in becomes a protocol, with Codex's file and Claude's Keychain item behind
  it;
- a window offers every runtime it can relay, not only Codex.

For Claude, the server's daemon sets three variables and writes no files (R7). Renewal is
left to the Mac's own `claude` (R6), so the app only ever reads Claude's Keychain item.

Then the token goes:
- two `CredentialKind` cases, the Claude check and the "needs a token" wording;
- Claude's saved Keychain item, deleted on first start;
- in their place, a `signInWanted` failure that opens 053's sign-in sheet (R8).

## Technical Context

**Language/Version**: Swift 6 (the app, AgentsKit, the Linux `agentsd`)

**Primary Dependencies**: Network.framework and Security (the Mac relay, as in 047),
`/usr/bin/security` (reading Claude's sign-in, R5), the Mac's own `claude` (renewal, R6)

**Storage**: none new. Claude's sign-in stays in Claude's own Keychain item and the app keeps
no copy. The app's `agents.runtime-credential.claude` item is deleted.

**Testing**: `swift test` (AgentsKit), unit tests with a fake sign-in source and a fake
upstream, as `MacSignInRelayTests` has for Codex; end to end with the test-servers skill on
agents-devbox and agents-bare; the Linux gate build

**Target Platform**: macOS app and daemon (relay); Linux `agentsd` on servers (gate, launch
environment)

**Project Type**: desktop app with a daemon and a server daemon

**Performance Goals**: no added delay a person notices on a model call. The Keychain read is
cached (R5), so a request costs one hop over the existing ssh master.

**Constraints**: nothing of the Mac's sign-in on a server, in logs or in the app's folder
(FR-002, FR-014). App code never renews, writes or deletes Claude's own Keychain item (R6).
No test ever renews Alex's sign-in.

**Scale/Scope**: one relay per runtime on the Mac, shared by every server and agent (FR-003)

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
gates. The project's working rules stand in for it:

- **Settle the UX before depth.** The visible change is subtractive. Settings loses a row,
  the runtime menu line changes wording, and a sheet goes. The one new thing a person sees
  is the `signInWanted` ending, which reuses 053's sheet. A single screenshot pass of
  Settings ▸ Servers and the runtime menu (Phase 2) is the look gate. No wireframes.
- **Walk it, don't hand it over.** Every user story is proven on agents-devbox or
  agents-bare with a real Claude turn (quickstart). Only the Terms check is Alex's.
- **Never mutate source to prove a test; no throwaway simulators.** Nothing here needs a
  simulator. Renewal is proven by observing Claude's own renewal (R6), not by forcing one.
- **The policy is total over the catalog.** Claude's relay policy lands in the same commit
  as the generalised `SignInRelay`, and the `ToolPolicyCatalog` test covers both relayed
  runtimes.

Post-design re-check: still passes. The design adds no new persistent store, no new screen
and no new process on the server.

## Project Structure

### Documentation (this feature)

```text
specs/056-claude-sign-in-relay/
├── spec.md
├── research.md          # R1–R2 spike, R3–R8 plan research
├── plan.md              # this file
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── relay.md         # relay/offer per runtime, Claude's launch environment, what the relay sends upstream
│   └── ui.md            # Settings ▸ Servers, the runtime menu line, the signInWanted ending
├── walk/relay-spike/    # R1 files
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Runtimes/ToolPolicy.swift          # SignInRelay: macSignIn source, server pointing, cleared variables
├── Runtimes/ToolPolicyCatalog.swift   # Claude's relay policy; Codex's in the new shape
├── Runtimes/CredentialKind.swift      # .oauthToken and .apiKey removed; Gemini only
└── Daemon/DaemonAPI.swift             # Failure.signInWanted (-32070); RelayOffer unchanged in shape

Packages/AgentsKit/Sources/AgentsKit/
├── Hosts/MacSignInRelay.swift         # relay takes a MacSignInSource; upstream headers from the policy
├── Hosts/MacSignIn/                   # new folder
│   ├── MacSignInSource.swift          # protocol: current(), renew(after:), standIn(), isSignedIn
│   ├── CodexFileSignIn.swift          # today's MacSignIn, moved
│   └── ClaudeKeychainSignIn.swift     # /usr/bin/security read, cache, renewal via the Mac's claude
├── Hosts/ServerConnection.swift       # offerRelay takes [RelayGrant]
├── Daemon/DaemonCore+Credentials.swift # relayOffers by connection and runtime; environment-style relay; signInWanted
└── Credentials/CredentialStore.swift  # delete a dropped kind's Keychain item; CredentialCheck loses Claude

App/Sources/
├── Hosts/SignInRelays.swift           # grants() for every relayed runtime
├── Hosts/HostSet.swift                # Claude through toolsetLine; install when relayable
├── Hosts/Lending.swift                # signInWanted → 053 sign-in sheet
├── Chat/TokenAskCard.swift            # Gemini's only: "needs a key"
└── Settings/ServersSettingsView.swift # Claude row gone; footer line

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/MacSignInRelayTests.swift     # + Claude source, header rules, cache, single renewal
├── Unit/ClaudeKeychainSignInTests.swift
├── Unit/CredentialKindTests.swift, CredentialStoreTests.swift, ToolPolicyTests.swift
└── Integration/LendTests.swift, RelayEndToEndTests.swift  # Claude relayed; signInWanted
```

**Structure Decision**: Everything lands in the files 043 and 047 already own. The one new
folder, `Hosts/MacSignIn/`, holds the sign-in sources that were one struct.

## Phases

**Phase 1: Generalise the relay (no visible change).**
- `SignInRelay` gets `macSignIn` (a file or a Keychain item) and `pointing` (Codex's home
  and files, or Claude's environment), plus the variables to clear and the upstream headers.
- `MacSignIn` becomes `MacSignInSource`, and Codex's implementation moves unchanged.
- `relayOffers` is keyed by connection and runtime.
- `ServerConnection.offerRelay` and `SignInRelays` handle a list of grants.

Codex's tests must pass untouched, apart from renames.

**Phase 2: Claude relayed.**
- Build `ClaudeKeychainSignIn` (R5) and Claude's policy (R7).
- The daemon builds Claude's relayed environment.
- The runtime menu line and the install-on-connect rule come from `toolsetLine`.

Proof: a real turn on agents-bare with no token saved, then the leak search. This is the
look gate: screenshots of Settings ▸ Servers and the runtime menu.

**Phase 3: the token removed.**
- `CredentialKind` loses its two cases, and with them the Claude check, the Claude row and
  the token wording.
- `CredentialStore` deletes the dropped item.
- Add `signInWanted` and route it to the 053 sheet.
- Docs.

**Phase 4: renewal.**
- A spike measures which command renews (R6).
- Build the single in-flight renewal and the proactive re-read at expiry.
- Proof: the SC-003 walk across a natural expiry.

**Phase 5: US5 and the endings.** Prove the gate refusal as a second account on devbox, then
walk each User Story 4 ending.

Phases 2 and 3 can swap. Phase 3 alone would leave servers with no way to run Claude, so
they merge together.

## Risks

- **Anthropic's terms.** This is Alex's check, before merge. The build doesn't depend on
  its outcome.
- **Renewal command.** If neither candidate in R6 renews, the fallback costs a one-token
  turn per expiry, a few a day at most. The app-side exchange stays rejected.
- **Claude changes where it keeps its sign-in.** The Keychain service name is a constant in
  one place. If the read fails, the relay reports "couldn't read Claude's sign-in"
  (FR-013), and nothing guesses.
- **052 (quota fallback)** counts turns against plans. Server Claude turns now spend the
  Mac's plan. Whichever of 052 and 056 merges second adapts.

## Complexity Tracking

None. The generalisation replaces one hard-wired runtime with a table the catalog already
had a slot for.
