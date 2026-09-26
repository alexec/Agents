# Tasks: Claude on Servers Through This Mac's Sign-in

**Input**: `specs/056-claude-sign-in-relay/`: plan.md, spec.md, research.md (R1–R8),
data-model.md, contracts/relay.md, contracts/ui.md, quickstart.md

**Tests**: included where the plan names them. This project proves every change with
`swift test` and a real walk on agents-bare or agents-devbox (the test-servers skill). The
`ToolPolicyCatalog` totality test forces Claude's relay policy into the same commit as the
generalised `SignInRelay`.

**Paths**:
- `Kit/` = `Packages/AgentsKit/`
- `Core/` = `Kit/Sources/AgentsKitCore/`
- `Daemon-side/` = `Kit/Sources/AgentsKit/`
- `Tests/` = `Kit/Tests/AgentsKitTests/`

**Standing rules for every task**:
- App code never writes, renews or deletes Claude's own Keychain item
  (`Claude Code-credentials`). It only reads it with `/usr/bin/security` (research R5, R6).
- No test renews Alex's sign-in. Tests use a fake `MacSignInSource` or a test-only Keychain
  service name.
- Never print, log or commit a token or any part of one. Leak searches take the last 24
  characters on stdin.
- Launch scratch apps with a clean environment (`env -i …`), and drive them only when Alex
  is away. Build the two Xcode schemes one after the other, with plugin validation skipped.
- No runtime-id `if` or `switch` outside the catalogs. Claude's relay details live in its
  `SignInRelay` policy.
- Stop any process a probe starts on a box by its pid. Never pattern-kill.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [ ] T001 Merge current `main` into `agents/claude-sign-in-relay`. Confirm `swift test` in `Kit/` passes, both Xcode schemes build, and `scripts/build-linux-agentsd.sh` builds, all before any change. Record the failing-test baseline (main's known flakes) in `specs/056-claude-sign-in-relay/walk/baseline.md`.
- [ ] T002 [P] Bring up agents-devbox and agents-bare (`.agents/skills/test-servers/scripts/devbox.sh up`, `bare.sh up`), and note in `walk/baseline.md` that `claude auth status` on the Mac says `"authMethod": "claude.ai"`.

---

## Phase 2: Foundational: the relay carries more than Codex (no visible change)

**Purpose**: Replace the relay's hard-wired Codex with a policy table (plan Phase 1).
Codex's behaviour must not change: its existing tests pass, with renames only.

- [ ] T003 In `Core/Runtimes/ToolPolicy.swift`, reshape `SignInRelay` into the fields in data-model.md § SignInRelay:
  - `upstreamHost`;
  - `macSignIn` (`enum MacSignInLocation { case file(String); case keychain(service: String) }`);
  - `pointing` (`enum RelayPointing { case home(homeVariable:configFile:signInFile:configTemplate:); case environment([String: String]) }`, where the values may hold `{port}` and `{standIn}`);
  - `certificateVariable`, `clearedVariables: [String]`, `upstreamHeaders: [String]` (names of `Token` fields to set as headers), and `ownSignInVariables: [String]` plus `ownSignInFile: String?`.

  Keep it `Codable, Hashable, Sendable`.
- [ ] T004 In `Core/Runtimes/ToolPolicyCatalog.swift`, restate Codex's relay in the new shape, meaning unchanged:
  - `.file(".codex/auth.json")`, `.home(CODEX_HOME, config.toml, auth.json, template)`;
  - `CODEX_CA_CERTIFICATE`, cleared `OPENAI_API_KEY` and `CODEX_API_KEY`;
  - `upstreamHeaders ["ChatGPT-Account-Id"]`.

  Add Claude's relay per research R7:
  - `upstreamHost "api.anthropic.com"`, `.keychain(service: "Claude Code-credentials")`;
  - `.environment(["ANTHROPIC_BASE_URL": "https://127.0.0.1:{port}", "CLAUDE_CODE_OAUTH_TOKEN": "{standIn}"])`;
  - `certificateVariable "NODE_EXTRA_CA_CERTS"`;
  - cleared `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`;
  - `upstreamHeaders []`;
  - `ownSignInVariables ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]`, `ownSignInFile ".claude/.credentials.json"`.
- [ ] T005 [P] Update `Tests/Unit/ToolPolicyTests.swift`: both relayed runtimes' policies round-trip through `Codable`; Codex's `config(gatePort:)` output is byte-identical to before; Claude's environment template resolves `{port}` and `{standIn}`.
- [ ] T006 Create `Daemon-side/Hosts/MacSignIn/MacSignInSource.swift` with the protocol in data-model.md: `isSignedIn`, `current() throws -> Token`, `renew(after:) async throws -> Token`, `standIn() throws -> String`. `Token` holds `access` and `headers: [String: String]`. Keep `MacSignIn.Failure` (`notSignedIn`, `renewalRefused`) and add `unreadable`.
- [ ] T007 Move today's `MacSignIn` out of `Daemon-side/Hosts/MacSignInRelay.swift` into `Daemon-side/Hosts/MacSignIn/CodexFileSignIn.swift`, conforming to `MacSignInSource`. `Token.headers` carries `ChatGPT-Account-Id`. The body is otherwise unchanged.
- [ ] T008 In `Daemon-side/Hosts/MacSignInRelay.swift`, take `any MacSignInSource`:
  - add `x-api-key` to `dropped`, and remove `chatgpt-account-id` from the always-dropped set only if it's now set from `Token.headers`;
  - set `Authorization: Bearer <access>`, then each of `token.headers`;
  - make `signIn` renewal and `standIn` go through the protocol.
- [ ] T009 [P] Update `Tests/Unit/MacSignInRelayTests.swift` for the protocol, using a fake source. Add:
  - `x-api-key` from the runtime never reaches upstream;
  - Codex's account header still does;
  - a source with no extra headers adds none.
- [ ] T010 In `Daemon-side/Daemon/DaemonCore.swift` and `DaemonCore+Credentials.swift`, make `relayOffers` `[UUID: [String: DaemonAPI.RelayOffer]]` (connection, then runtime). `offerRelay` adds or replaces one runtime's offer. `forgetCredentials` drops the connection's map. `relayEnvironment(for:)` looks up by runtime, preferring the current connection's offer and then any other's.
- [ ] T011 In `DaemonCore+Credentials.swift`, make `relayEnvironment(for:)` follow `relay.pointing`:
  - `.home`: today's code, unchanged;
  - `.environment`: write only the offer's CA to `<root>/runtimes/<runtime>-relay-ca.pem` (0600), and return the template with `{port}` set to the gate's port and `{standIn}` set to `offer.standIn`, plus `certificateVariable`.

  Either way, remove `relay.clearedVariables` from the launch environment: extend `LentEnvironment.applied`, or return a removal list alongside, whichever `SessionLauncher` already supports.
- [ ] T012 In `Daemon-side/Hosts/ServerConnection.swift`, change `relay: () async -> RelayGrant?` to `() async -> [RelayGrant]`. `offerRelay(home:)` forwards `relay-<runtime>.sock` and sends one `relay/offer` per grant (contracts/relay.md).
- [ ] T013 In `App/Sources/Hosts/SignInRelays.swift`, replace `grant()` with `grants()`. It covers every runtime in `RuntimeCatalog.builtIn` whose policy has a `relay`, building its source from `macSignIn`: `.file` → `CodexFileSignIn`, `.keychain` → `ClaudeKeychainSignIn` (T018). Only signed-in ones are granted. `canRelay(_:)` asks the same source. Update `HostSet.relayFor` and `HostSet.connection(…)` in `App/Sources/Hosts/HostSet.swift` for the list.
- [ ] T014 [P] Update `Tests/Integration/RelayEndToEndTests.swift` and `Tests/Unit/RelayGateTests.swift` for per-runtime offers. Two runtimes' offers on one connection coexist, and a second offer for the same runtime replaces the first.
- [ ] T015 Run `swift test`. Build both schemes and `scripts/build-linux-agentsd.sh`. Walk Codex once on agents-bare (the test-servers skill, as 047's quickstart does) to show nothing changed. Commit: "056 Phase 2: the relay is a table, not Codex".

**Checkpoint**: Codex works as before, and the relay can carry a second runtime.

---

## Phase 3: User Story 1: Claude on a server with nothing to set up (P1) 🎯 MVP

**Goal**: A Claude agent on a server signs in through this Mac with no token anywhere.

**Independent Test**: quickstart § 1. On agents-bare with no Claude credential in Settings,
a real `uname -a` turn answers, and the leak search says `clean`.

- [ ] T016 [US1] Spike before code (research R5). In a throwaway script under `/tmp`, time 20 reads of `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, printing only the durations and whether `scopes` contains `user:inference`. Record the median in research R5, which confirms whether caching is needed.
- [ ] T017 [P] [US1] Tests in `Tests/Unit/ClaudeKeychainSignInTests.swift`, with an injected reader (a closure returning the item's JSON or an error):
  - signed in only when the JSON parses and `scopes` contains `user:inference` (D3);
  - `current()` returns `claudeAiOauth.accessToken` with no extra headers;
  - the cache is reused until `expiresAt − 60 s` and dropped by `invalidate()`;
  - a reader error gives `unreadable`, and a missing item gives `notSignedIn`;
  - `standIn()` is exactly `sk-ant-oat01-agents-relay-standin`;
  - the type's `description` and the log lines never contain the access token.
- [ ] T018 [US1] Create `Daemon-side/Hosts/MacSignIn/ClaudeKeychainSignIn.swift`, conforming to `MacSignInSource` per data-model.md § ClaudeKeychainSignIn:
  - read with `/usr/bin/security find-generic-password -s <service> -w`, ending the process on `terminationHandler` (never `waitUntilExit` off the main thread);
  - parse, cache until `expiresAt − 60 s`;
  - `standIn()` is the constant.

  `renew(after:)` for now: re-read, and return the new token if it differs, else throw `renewalRefused(0)`. Phase 5 adds asking the Mac's Claude. The service name is injectable for tests and walks, defaulting to the policy's.
- [ ] T019 [US1] In `MacSignInRelay.forward`, call the source's `invalidate()` before the 401 path's `renew(after:)`, so a renewal by the Mac's Claude is picked up (FR-005). Test in `Tests/Unit/MacSignInRelayTests.swift`: a fake source whose token changes after the first 401 gets the request through on the second asking, with no renewal counted.
- [ ] T020 [US1] In `DaemonCore+Credentials.swift`, make `ServerSignIn.exists(runtimeID:)` read `ownSignInVariables` and `ownSignInFile` from the runtime's relay policy, not from `CredentialKind`, so it keeps working once Claude's kinds go (T027).
- [ ] T021 [US1] In `App/Sources/Hosts/HostSet.swift`, fold `claudeLine` into `toolsetLine` so Claude reads as a relayed runtime (contracts/ui.md table). Install Claude on connect when `SignInRelays.canRelay("claude")` and the host isn't `ownSignInOnly`, as `serverRuntimes` already does for Codex. Update the callers in `App/Sources/Settings/ServersSettingsView.swift` and the runtime menu.
- [ ] T022 [US1] Test in `Tests/Integration/LendTests.swift` (or a new `Tests/Integration/ClaudeRelayTests.swift`): a fake server daemon with a Claude relay offer starts Claude with `ANTHROPIC_BASE_URL=https://127.0.0.1:<gate>`, `CLAUDE_CODE_OAUTH_TOKEN=<stand-in>` and `NODE_EXTRA_CA_CERTS` set, and with `ANTHROPIC_API_KEY` from the login environment removed (spec edge case). Assert the stand-in holds no part of the fake Mac token.
- [ ] T023 [US1] Walk quickstart § 1 on agents-bare (`bare.sh rebuild` first) with a scratch root (the run-app and test-servers skills):
  1. Add the server. **Install Claude** runs unasked.
  2. Screenshot the runtime line.
  3. Run a real `uname -a` turn, then a helper (028), then an agent started through the daemon socket as the Remote would.
  4. Check `relay.log` holds only method, path and status.
  5. Run `scripts/leak-check.sh` with the token tails on stdin: `clean`.

  Put the screenshots and notes in `specs/056-claude-sign-in-relay/walk/US1.md`. Commit.

**Checkpoint**: Claude runs on a bare server with nothing pasted. The old token path still
exists underneath until US2.

---

## Phase 4: User Story 2: The token is gone (P1)

**Goal**: No Claude token anywhere: not in Settings, not in the Keychain, not in any
wording.

**Independent Test**: quickstart § 2. A scratch root that held a Claude token starts
without it, and Settings ▸ Servers shows no Claude row.

- [ ] T024 [US2] Add `Failure.signInWanted = -32070` in `Core/Daemon/DaemonAPI.swift`, with `struct SignInWanted: Codable { runtime: String; reason: Reason }` and `enum Reason: String { case notSignedIn, unreadable }` (contracts/relay.md). Check `-32070` is still free on `main` and every `agents/*` branch first.
- [ ] T025 [US2] In `DaemonCore+Credentials.swift`, `launchEnvironment(for:)` follows data-model.md § Launch decision for any runtime whose policy has a relay and no `CredentialKind`:
  - own sign-in only → `[:]`;
  - relay offered → relayed environment;
  - server has its own → `[:]`;
  - else throw `signInWanted` with reason `notSignedIn`.

  The message is "Claude on this Mac isn't signed in with a Claude account." (FR-013). The window sends the reason it knows with its offer. Add `macSignIn: Reason?` per runtime to `CredentialsOffer`, so `unreadable` reaches the server.
- [ ] T026 [US2] Tests in `Tests/Integration/LendTests.swift`, replacing the Claude-token cases:
  - no offer, no own sign-in → `signInWanted`/`notSignedIn`;
  - no offer, own sign-in → starts with `[:]`;
  - own-only → `[:]` and no relay;
  - an unreadable Mac sign-in → `signInWanted`/`unreadable`.

  Remove the tests that lent a Claude token, and keep Gemini's.
- [ ] T027 [US2] In `Core/Runtimes/CredentialKind.swift`, delete `.oauthToken` and `.apiKey` and every branch for them. Gemini's key is the only kind. `noun`, `whereToGet` and `pasteRefusal` lose their Claude defaults. `allVariables` goes, and its callers use the Claude relay policy's `ownSignInVariables` (T020). Fix each compile error in `Kit/` and `App/` by deleting the Claude path, not by adding one.
- [ ] T028 [US2] In `Daemon-side/Credentials/CredentialCheck.swift`, delete the Claude check. In `Tests/Unit/CredentialCheckTests.swift` and `Tests/Unit/CredentialKindTests.swift`, delete the Claude cases and keep Gemini's.
- [ ] T029 [US2] In `Daemon-side/Credentials/CredentialStore.swift`, when a record's kind no longer decodes (the per-entry decode from f10cd50), delete that runtime's Keychain item `agents.runtime-credential.<runtime>` once and drop the record from `credentials.json`. Test in `Tests/Unit/CredentialStoreTests.swift` with a test Keychain service: a stored Claude record and item go, and a Gemini record and item stay (FR-010).
- [ ] T030 [US2] In `App/Sources/AppModel.swift` `fail(_:on:)`, a `signInWanted` from any host opens this Mac's sign-in sheet (`signInRuntimeID = runtime`). The agent's ending shows the sentence for its `reason` and a **Use <server>'s own sign-in** button that opens Settings ▸ Servers at that server (contracts/ui.md § The signInWanted ending).
- [ ] T031 [US2] In `App/Sources/Chat/TokenAskCard.swift` and `App/Sources/Hosts/Lending.swift`, make the ask Gemini's only: "<name> on <server> needs a key", with no Claude wording. Delete the `credentialRefused` Claude sentence path in `App/Sources/AppModel.swift` (search "refused the token").
- [ ] T032 [US2] In `App/Sources/Settings/ServersSettingsView.swift`, iterate only runtimes with a `CredentialKind` (now Gemini alone). Set the footer to the text in contracts/ui.md § Settings ▸ Servers.
- [ ] T033 [US2] `grep -rn "setup-token\|needs a token\|refused the token\|sk-ant-oat\|sk-ant-api" App/ Kit/Sources` finds nothing except the stand-in constant in `ClaudeKeychainSignIn.swift` (FR-011). Fix any other hit.
- [ ] T034 [US2] Walk quickstart § 2 on a scratch root:
  1. Save a made-up `sk-ant-oat01-…` with a build of `main`.
  2. Start this branch's build. The Keychain item is gone (metadata-only `security find-generic-password`), and Gemini's is kept.
  3. Screenshot Settings ▸ Servers. This is the look gate: show Alex the screenshots with `show_file`, as the only visual change.

  Record in `walk/US2.md`. Commit.

**Checkpoint**: MVP (US1 + US2) is mergeable once Alex has done the Terms check.

---

## Phase 5: User Story 3: Long runs don't sign anyone out (P2)

**Goal**: A server's Claude survives the Mac's sign-in expiring while the Mac is idle,
without the app ever renewing it.

**Independent Test**: quickstart § 5. A job on a server carries on across a natural expiry,
and `claude` on the Mac is still signed in afterwards.

- [ ] T035 [US3] Spike (research R6), timed to a natural expiry. Read `expiresAt` (print only the time). Just after it passes, with no Claude running on the Mac, run `claude auth status` and read `expiresAt` again.
  - If it moved, the renewal command is `claude auth status`.
  - Otherwise try `claude -p . --max-turns 1 --model haiku` at the next expiry.

  Record which, and how long it took, in research R6. Never run anything that renews from app code.
- [ ] T036 [US3] In `ClaudeKeychainSignIn.renew(after:)`:
  1. Re-read. If the token differs, return it.
  2. Otherwise run the command T035 chose through the Mac's own `claude` (found as `SessionLauncher` finds it on the Mac, with the login environment), limited to 30 s.
  3. Re-read. Return the new token, or throw `renewalRefused`.

  Only one renewal runs at a time: a stored `Task` every caller awaits, cleared when it ends. Also invalidate proactively at `expiresAt`, so an expired token is never sent.
- [ ] T037 [P] [US3] Tests in `Tests/Unit/ClaudeKeychainSignInTests.swift` with a fake reader and a fake renewer:
  - two concurrent `renew(after:)` calls run the renewer once and both get the new token;
  - a token already changed runs no renewer;
  - a renewer that leaves the token unchanged throws `renewalRefused`;
  - a renewer that hangs is cut off at the limit.
- [ ] T038 [US3] On the server's daemon, a Claude turn that ends in `authentication_failed` while relayed ends with "Claude on this Mac needs signing in again." Route it through `credentialRefusal` in `DaemonCore+Credentials.swift` (no longer tied to a lent token) and the window's handler in `App/Sources/AppModel.swift`, which offers the Mac's sign-in sheet (US3 scenario 3).
- [ ] T039 [US3] Walk quickstart § 5.2 across a natural expiry: a server job asking Claude something every 10 min, with Claude on the Mac idle. The job carries on, `relay.log` has one `renewing` line per expiry, and `claude auth status` on the Mac still says logged in. Record in `walk/US3.md`. Commit.

---

## Phase 6: User Story 4: When the Mac can't lend it (P2)

**Goal**: Each case ends in one sentence within 10 s (SC-006).

**Independent Test**: quickstart § 3.

- [ ] T040 [US4] Walk each ending on a scratch root, recording times and screenshots in `walk/US4.md`:
  1. The Mac is "signed out", using `ClaudeKeychainSignIn`'s injectable service name set to a service that doesn't exist, via a test-only launch variable. Never sign Alex out. The turn ends with the sentence and the **Sign in** and **Use <server>'s own sign-in** buttons.
  2. Own sign-in only on agents-devbox. It runs, and `relay.log` gains nothing.
  3. The same box unmarked: `relay.log` gains lines (D7).
  4. The ssh master stopped mid-turn: 037's offline sentence.
- [ ] T041 [US4] Fix whatever T040 finds. If the test-only service-name variable was added, confirm it's read only in DEBUG builds or from a scratch root, and never on the real app. Commit.

---

## Phase 7: User Story 5: Nobody else on the server can use it (P2)

**Goal**: Only the connecting account's processes can use the relay (D5, SC-004).

**Independent Test**: quickstart § 4.

- [ ] T042 [US5] Walk quickstart § 4 on agents-devbox:
  1. Create a second account (`devbox.sh ssh 'sudo useradd -m other'`).
  2. As that account, `curl -sk https://127.0.0.1:<Claude's gate port>/v1/messages`. It's refused.
  3. `relay.log` has the `refused` line with the uid.
  4. The person's own turn still works.
  5. Remove the account afterwards.

  Record in `walk/US5.md`. If the gate lets it through, fix it in `Daemon-side/Hosts/RelayGate.swift` with a test in `Tests/Unit/RelayGateTests.swift` before committing.

---

## Phase 8: Polish & Cross-Cutting

- [ ] T043 [P] Update `docs/how-to/add-a-linux-server.md` per spec § Docs:
  - drop **Give Claude a token**;
  - a Claude section beside Codex's;
  - the checklist and runtime-menu wording;
  - "own sign-in only";
  - the troubleshooting entries.
- [ ] T044 [P] Update `docs/reference/settings.md` and `docs/reference/runtimes.md` (Claude on servers uses this Mac's sign-in), and `docs/how-to/sign-a-runtime-in.md` (signing Claude in on the Mac also signs it in on servers).
- [ ] T045 [P] Update `.agents/skills/test-servers/SKILL.md` § 1: a Claude turn on a server needs this Mac signed in, not a pasted token. Replace the leak-check instructions with the token-tail-on-stdin form in quickstart § 1.
- [ ] T046 Merge `main` again. Then run the full `swift test`, compared against `walk/baseline.md`, build both schemes and `scripts/build-linux-agentsd.sh`. Note in `walk/merge-readiness.md` what 052 (quota fallback) needs if it merged first: server Claude turns spend the Mac's plan.
- [ ] T047 Ask Alex (AskUserQuestion) whether he has checked Anthropic's terms for relaying his subscription sign-in to his own servers, and whether to merge. Do not merge before he answers.

---

## Dependencies & Execution Order

- **Phase 1** → **Phase 2** (blocks everything).
- **US1 (Phase 3)** needs Phase 2.
- **US2 (Phase 4)** needs US1's T020 (own-sign-in check off `CredentialKind`) before T027.
  US1 and US2 merge together: US2 alone would leave servers no way to run Claude.
- **US3 (Phase 5)** needs US1. T035 waits for a natural expiry, so start it whenever one
  is due, alongside other work.
- **US4 (Phase 6)** needs US2 (the `signInWanted` ending).
- **US5 (Phase 7)** needs US1 only.
- **Polish** last. T047 gates the merge.

## Parallel Opportunities

- Phase 2: T005, T009 and T014 (tests in separate files) alongside the code they cover,
  once T003 has landed.
- US1: T017 (tests) alongside T016 (spike).
- US3's T035 runs on the clock, not in order. Take the next expiry after Phase 2.
- US5 (T042) can run any time after US1.
- Polish: T043, T044 and T045 are separate files.

## Implementation Strategy

1. **MVP = US1 + US2** (Phases 1–4). Claude on servers through the Mac and the token gone.
   The look gate is T034's screenshots.
2. **Then US3.** Without it, a server's Claude stops once the Mac's sign-in expires
   unrenewed, which happens only when Claude on the Mac sits idle for hours.
3. **Then US4 and US5**, walks with small fixes.
4. Merge only on Alex's word, after his Terms check (T047).
