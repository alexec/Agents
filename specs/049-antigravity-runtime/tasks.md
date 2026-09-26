---
description: "Task list for 049, Google Antigravity as a runtime"
---

# Tasks: Google Antigravity as a Runtime

**Input**: `specs/049-antigravity-runtime/` (plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md)

**Base**: main at 48b2c64. 047's Mac half is already here: `Runtime.usesAppCopyOnly`, every
bundled toolset keyed by runtime (`Toolset.loadAll`, `RuntimeInstaller.toolsets`), **Update** on
an outdated toolset, kept folders, and `scripts/update-toolset.sh`. The per-runtime 043
generalisation (credential kinds, lending, server toolsets) is **not** on main yet. 046 Gemini
and 047's server half both plan it, and T040 does it here if neither has landed by then.

**Rebased on main at 14c9723 (2026-09-25)**, which brings in 046 Gemini, the dotagents layout
and pairing. 046 brought the per-runtime 043 generalisation: `CredentialKind.geminiAPIKey`, and
`lendableRuntimes` worked out from the kinds. So **T040 is not needed**. (T027 was unblocked by this, then dropped: see the revision note.)

**Tests**: the plan names them, so they are included. Paths are relative to the repo root.
`Core/` = `Packages/AgentsKit/Sources/AgentsKitCore/`, `Kit/` = `Packages/AgentsKit/Sources/AgentsKit/`,
`Tests/` = `Packages/AgentsKit/Tests/AgentsKitTests/`.

**Rules that hold for every task**:
- There are no `"antigravity"` branches outside the catalogs.
- Never touch `~/.gemini`. Probes use `HOME`/`GEMINI_HOME` in `/tmp`.
- Never commit Google's bytes, only URLs and checksums.
- Scratch roots only, and never the real daemon.sock.
- `xcodebuild` needs `-skipPackagePluginValidation`, one scheme at a time.

> **Revised 2026-09-26 (Alex): Antigravity signs in with a Google account only.** The Gemini key
> in Settings is Gemini's and is never lent to Antigravity, and Antigravity has no key of its own
> (spec D3, D6). Servers use the Mac's Google sign-in, copied (D8), with no key fallback. So the
> lent-key sign-in (`lentKeyAuthMethod`, T026), sharing the key (T027), the Settings wording
> (T031) and the key fallback on servers are **removed**. `RuntimeLaunch.hiddenAuthMethods` takes
> the key and Agent Platform choices off the sign-in sheet. A turn that fails in words ends as
> `runtimeError`, with no refused-key case. Anything below that still says "key" for Antigravity is
> history.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup (the spike, which settles research.md's "to measure")

**Needs Alex**: a Google sign-in on the scratch probe, or a real Gemini API key. Both are
lease-free, but it's his account. Probes run the downloaded server directly with
`GEMINI_HOME=/tmp/agy-spike/home`.

- [ ] T001 Write `scripts/probe-antigravity.py`, a small ACP client from `/tmp/agy-acp/probe2.py`:
  - it runs initialize, authenticate, session/new, prompt, load and list;
  - it logs every line with a timestamp;
  - it answers `session/request_permission` with the first option;
  - it takes `--key-env` and `--method`.
- [X] T002 Spike the Google sign-in. Record the result in research.md R5/R6.
  - Run `authenticate {oauth-personal}` with Alex, and record whether the server opens the
    browser itself or returns a URL, and what arrives on the wire meanwhile.
  - Record the Keychain service name (`security find-generic-password -l …`) and whether two
    `GEMINI_HOME`s share it.
  - Record what `logout` removes.
  *Done 2026-09-25 with Alex (research R6a, R6b)*: the server opens the browser itself. With forced file storage the Keychain isn't used, so it has no service name to find. A copied `acp_token.json` signs in headless in under 1 s, and the refresh token was not rotated. `logout` deletes the token file and resets `settings.json`, but revokes nothing.
- [X] T003 Spike a real turn with the app's MCP server passed in `session/new.mcpServers` (the
  command `Kit/ACP/Serve` builds for other runtimes). Record in research.md R4/R7/R11:
  - the MCP tools the model can call;
  - the real built-in tool names seen in `tool_call`s;
  - whether `finish` competes with the app's `finish_turn`;
  - whether a browser subagent is offered;
  - whether a turn reports usage.
  *Done (R6b)*: MCP arrives, but every MCP call asks permission (→ T035a). The real tool names are listed there. The subagent family goes with `start_subagent`. There is no `finish` tool and no browser subagent. No usage is reported.
- [X] T004 Spike questions and trust. Record in research.md R7.
  - Prompt the model to use `ask_question`, and record the exact `session/request_permission`:
    its title, options, kinds, and the `interaction_` tool call id.
  - Start `session/new` in a fresh folder once without `AGY_ACP_DISABLE_WORKSPACE_TRUST` and once
    with it, and record the difference.
  *Done (R6b)*: questions arrive exactly as predicted. The trust variable made no visible difference.
- [X] T005 Spike failure text. Record in research.md R3/R6/R9.
  - A quota or rate-limit error, if one can be provoked on the free tier.
  - Removing `GEMINI_API_KEY` after `auth.type=gemini-api-key` was persisted: what `session/new`
    and a prompt return.
  - `session/load` of an ended session: does it replay history as `session/update`s?
  *Partly done (R6b)*: load replays history. A quota error couldn't be provoked, and the removed-key case hasn't been tried.
- [X] T006 Spike Linux, and record in research.md R12 and the manifest's `minFreeBytes`/`knownBroken`.
  - On agents-bare (x86_64): download the 334 MB zip, run with `--uid=`, a handshake and a turn
    with a lent key, and record the unpacked size and what `--uid=` does.
  - On the devbox (arm64, Colima): does it start, or hit the reported TCMalloc crash?
  *Done 2026-09-25 on `agents-bare` (arm64). Results are in research R6a and R12: arm64 works; x86_64 needs AVX, and the emulator lacks it, so a real x86_64 turn is still owed; the server has no unzip; the token path is `antigravity-acp/acp_token.json`; headless Google sign-in waits for ever on a missing or refused token.*
- [ ] T007 Bring any finding that overturns a plan decision (for example: no browser opens,
  `finish` must go, arm64 works) to Alex with AskUserQuestion before Phase 3. Update plan.md
  and contracts to match.

**Checkpoint**: research.md has no "to measure" left, and the contracts match what was seen.

---

## Phase 2: Foundational (blocking: the archive toolset and the runtime fields)

- [X] T008 [P] Add the archive shape to `Core/Runtimes/Toolset.swift`, per
  contracts/toolset-archive.md.
  - `ArchiveManifest` holds `runtimeID`, `kind: "archive"`, `version`, `source`, `minFreeBytes`,
    and `platforms: [String: Platform]`.
  - `Platform` holds `url`, `sha256`, `size`, `command`, `arguments`, and `knownBroken: String?`
    ("absent = fine").
  - `Toolset.load` reads either shape. An archive toolset has no lock file, and its id is the
    "first 16 hex of SHA-256 of `manifest.json`'s bytes (no lock file)".
  - Add `platform(for:)`, which returns `darwin-aarch64`/`darwin-x86_64` on the Mac and
    `linux-x86_64`/`linux-aarch64` from `Architecture`.
  - `shimLines` for an archive: `exec "$d/<command>" <arguments> "$@"`.
- [X] T009 [P] Add the unit tests in `Tests/Unit/ToolsetTests.swift`:
  - an archive manifest decodes;
  - the id is stable and changes when a byte changes;
  - the platform is chosen for each architecture;
  - `knownBroken` is surfaced;
  - the shim passes `--uid=` and `"$@"`;
  - a Node manifest's id is unchanged by this work, so existing pins don't reinstall.
- [X] T010 Add four optional fields to `Core/Model/Runtime.swift`, decoded with `decodeIfPresent`
  so old data still reads:
  - `launchEnvironment: [String: String?]`, where `nil` means remove the variable and `<root>`
    is substituted;
  - `lentKeyAuthMethod: String?`;
  - `turnErrorPrefix: String?`;
  - `signInNotice: SignInNotice?`, holding `text`, `url` and `methods: [String]`.
  *Done differently*: the four fields live in a new catalog, `Core/Runtimes/RuntimeLaunch.swift` (`RuntimeLaunchCatalog`), keyed by runtime id like the tool policy, not on `Runtime`. `Runtime` travels to the phone and to older daemons, and none of these fields are theirs. `lentKeyVariable` and `refusedKeyMarkers` were added.

  Every existing runtime leaves them empty.
- [X] T011 [P] Add the archive mode to `scripts/update-toolset.sh`: `--archive antigravity-acp`.
  - Read `https://raw.githubusercontent.com/agentclientprotocol/registry/main/<id>/agent.json`.
  - Refuse any URL that is not on `https://dl.google.com/`.
  - Download each platform to a temp folder, record `size` and `sha256`, and map the registry's
    `cmd` (strip `./`) and `args`.
  - Write `App/Resources/toolsets/<runtime>/manifest.json` with keys sorted.
  - Keep `knownBroken` values across runs.
- [X] T012 Run T011 to create `App/Resources/toolsets/antigravity/manifest.json`.
  - Check that `darwin-aarch64.sha256 == 0fab9938812e6b32b3b543e65e4f3a0025ceef755413db13542d9a9b81ea803c`
    and `size == 111725488`.
  - Set `minFreeBytes` from T006 (the Mac's unpacked size is 399 MB).
  - Set `linux-aarch64.knownBroken` per T006.
  - Make sure the Xcode project copies the folder into the bundle as it does `toolsets/codex`
    (`App/project.yml` or the pbxproj resource entry).
  *Done*: `minFreeBytes` is 2 GB (Linux unpacks to 1.0 GB, about 1.35 GB at peak). `linux-aarch64` is not `knownBroken`, because it ran on arm64 (T006).

**Checkpoint**: `swift test --filter ToolsetTests` passes, and the bundle carries the manifest.

---

## Phase 3: User Story 1, Antigravity agents on the Mac (P1) 🎯 MVP

**Goal**: install from the set-up page, start an agent, and get a turn with tools, permission,
diffs, stop and resume.

**Independent test**: quickstart.md §2 and §3, with a key in the scratch root's Settings, or
Alex's sign-in once US2 is done.

### Install

- [X] T013 [US1] Add the archive path to `Kit/Runtimes/MacToolsetInstaller.swift`, following
  contracts/toolset-archive.md steps 1–7.
  1. Refuse when free space is under `minFreeBytes` ("Not enough room: Antigravity needs about
     N GB.").
  2. Refuse a missing or `knownBroken` platform.
  3. Download `url` to `<id>.partial/archive.zip` with URLSession, reporting
     `InstallStep` progress as bytes of `size`.
  4. Check the SHA-256. On a mismatch, remove the partial folder ("The download from Google did
     not match what this app expects.").
  5. Run `/usr/bin/ditto -x -k`, delete the zip, and write `bin/agy_acp_server` from
     `shimLines` with mode 0755.
  6. Rename to `<id>`, write `ok` last, and point `current` at it.
  7. Keep the folders in use (047's rule).
  - A leftover `.partial` is removed at the next install.
- [X] T014 [US1] Dispatch on the toolset's shape in `Kit/Runtimes/RuntimeInstaller.swift`.
  - `installable` is true for an archive toolset when its platform exists and isn't
    `knownBroken`. Today it requires `macNode`.
  - `install` calls the archive path.
  - The row's words name the runtime and the size ("112 MB from Google").
- [X] T015 [P] [US1] Add the archive tests to `Tests/Unit/MacToolsetInstallerTests.swift`,
  against a `file://` zip made in the test with `ditto -c -k` of a fake `agy_acp_server.par`
  shell script. Cover:
  - a good install (`ok`, `current`, a shim that runs);
  - a checksum mismatch (nothing left behind);
  - a truncated download;
  - no room;
  - `knownBroken`;
  - a leftover `.partial` removed;
  - a running agent's folder kept on update.
- [X] T016 [US1] Set the size and progress text in `App/Sources/Runtimes/InstallAgentsSheet.swift`.
  - The row shows "112 MB download from Google" before **Install**.
  - The progress shows "34 of 112 MB" from `InstallStep`.
  - Keep the one-element-per-row accessibility rule (memory: stacked labels crash AppKit).

### The runtime

- [X] T017 [US1] Add `antigravity` to `Core/Runtimes/RuntimeCatalog.swift` and to `builtIn`,
  after `codex`.
  - `executable: "agy_acp_server"`, `arguments: []`, `install: .toolset(runtimeID: "antigravity")`.
  - `installPage: https://antigravity.google/docs/ide/extensions`, `usesAppCopyOnly: true`.
  - `launchEnvironment`: `GEMINI_HOME = "<root>/runtimes/antigravity/home"`,
    `AGY_ACP_DISABLE_WORKSPACE_TRUST = "1"`, `GOOGLE_API_KEY = nil`, `GEMINI_API_KEY = nil`.
  - `lentKeyAuthMethod: "gemini-api-key"` and `turnErrorPrefix: "Agent execution error:"`.
  - A doc comment says why it is the ACP server and not `agy` (R1).
- [X] T018 [US1] Add the `antigravity` policy to `Core/Runtimes/ToolPolicyCatalog.swift`, in the
  same commit as T017.
  - `lever: .sessionMetaDenyList(path: ["agy", "disabledTools"])`.
  - `removed: [start_subagent (.agents)]`, plus `finish (.escalation)` if T003 says it competes.
  - `kept`: `ask_question` ("the only way it can ask the person"), `generate_image`,
    `search_web`, `read_url_content`.
  - `residue`: the `/plan` command (`.artefacts`), plus a browser subagent if T003 found one.
  - `escalationTool: "ask_question"`.
  - Measured facts go in comments, as for Grok.
- [X] T019 [P] [US1] Add to `Tests/Unit/ToolPolicyTests.swift`:
  - the catalog-totality test covers antigravity;
  - `sessionMeta` for antigravity is exactly `{"agy": {"disabledTools": ["start_subagent"]}}`,
    sent on new, load and resume.
- [X] T020 [US1] Apply `launchEnvironment` in `Kit/ACP/RuntimeEnvironment.swift`.
  - Add `forRuntime(_:root:base:)`, which applies it on top of `forRuntimes()`: `nil` removes,
    and `<root>` is replaced with the daemon's root.
  - The home folder is created with 0700 before launch, in `Kit/ACP/RuntimeProcess.swift` or its
    caller.
  - Test in `Tests/Unit/RuntimeEnvironmentTests.swift`:
    - a stray `GEMINI_API_KEY` in the daemon's environment is removed;
    - `<root>` is substituted;
    - other runtimes are unchanged.
- [X] T021 [US1] Add turn errors from text in `Kit/ACP/ACPSession.swift`.
  - Error text is detected only when the runtime has a `turnErrorPrefix` and the turn's agent
    text begins with it.
  - The turn then ends as failed with the inner message: strip the prefix, the outer quotes and
    `request failed (code N):`.
  - "API key not valid" or `API_KEY_INVALID` becomes the refused-key failure that 043 already
    shows, with **Replace key**.
  - A fake-runtime test in `Tests/Integration/` replays the exact R9 lines.
- [X] T022 [US1] Make discovery cheap in `Kit/Runtimes/RuntimeDiscovery.swift`.
  - An app-copy-only runtime is found through `current/ok` (047).
  - The handshake probe result is cached per toolset id, so a refresh doesn't re-run a 7–10 s
    `initialize`.
  - Check the daemon's handshake limit (`Kit/Daemon/DaemonCore+Runtimes.swift`,
    `Kit/ACP/ACPSession.swift`), and raise it to at least 30 s if it is lower. Add a test with a
    fake runtime that answers `initialize` after 8 s.
  *Found*: nothing in the daemon calls `RuntimeDiscovery.probe`. Discovery is file-based (`current/ok`), so it runs no handshake to cache, and `initialize` has no timeout to raise. `probe` was given the launch environment anyway, so it can never fall back to `~/.gemini`.
- [X] T023 [US1] Add antigravity to `scripts/acp-handshake.sh` and `scripts/runtime-tools.sh`.
  - They run the app's copy under the scratch root, with `GEMINI_HOME` in `/tmp`.
  - Expect four `authMethods`, `loadSession: true`, and the version equal to the manifest's.
- [ ] T024 [US1] Add a live test gated on `AGENTS_ANTIGRAVITY=1`, in
  `Tests/Live/AntigravityLiveTests.swift`:
  - a real turn with the key from the environment;
  - it creates a file and runs `ls`;
  - `_meta` removed `start_subagent` from what the model sees (`runtime-tools.sh`);
  - `~/.gemini`'s checksums are unchanged before and after.
  *Status*: `Tests/Live/AntigravityLiveTests.swift` runs against the real server via `AGENTS_ANTIGRAVITY_SERVER`. Two of its three tests pass: the no-key `-32000`, and a lent key being signed in with then refused. `~/.gemini` stays unchanged apart from Google's harness encoder (R5). The real-turn test needs `AGENTS_ANTIGRAVITY_KEY`.
- [X] T025 [US1] **Look gate and walk** (run-app skill, scratch root, `-ApplePersistenceIgnoreState YES`).
  - Before any walk, record a baseline with `find ~/.gemini -type f -exec shasum {} +`.
  - The set-up sheet lists Antigravity with its size. **Install** shows progress, then a tick.
    Screenshot for Alex.
  - With a key in the scratch Settings, a turn shows:
    - an edit with its diff;
    - `ls`;
    - a permission card;
    - a question card from `ask_question`;
    - stop mid-turn;
    - resume with history;
    - a picture.
  - Starting while it's not installed offers **Install**.
  - `~/.gemini` is unchanged against the baseline.
  - Screenshots go in `specs/049-antigravity-runtime/walk/`.

  *Walked 2026-09-26 on a scratch root (`/tmp/run-agy`, this branch at 7f2a316), with Alex's Google sign-in*:
  - The set-up sheet showed "Antigravity · Not on this Mac · 112 MB from Google" with **Install**. Install
    took 6 s (progress was too quick to see) and left the row ticked with the app's copy. `current`, `ok`
    and the shim were as designed.
  - Starting unsigned was refused with "Antigravity needs signing in", and the runtime menu showed
    "Needs signing in".
  - The sheet showed "Installed, and needs signing in", only the two Google choices, and the terms
    line and link.
  - **Log in with Google** opened Alex's browser, and the account read `ready` 5 s later. The sign-in
    landed in `<root>/runtimes/antigravity/home/antigravity-acp/acp_token.json` (0600), and nothing new
    went into `~/.gemini`.
  - A real turn wrote hello.txt (with its diff), ran `ls`, and ended with `agents_finish_turn`,
    auto-allowed with no card (T035a). It reported **done**.
  - The start form showed Antigravity's own modes and "Model: Gemini 3.8 Flash (High)".
  - Found: T025a, T025b.
- [X] T025a [US1] **One write, two permission cards.** Antigravity asks "Run client_create_file?"
  (its own card, with the diff), then the app asks again at `fs/write_text_file` ("Write hello.txt").
  Either offer Antigravity no `writeTextFile`, so it writes itself after its own card (as Gemini's
  `readsFilesItself` does for reads), or answer the app's write card when the runtime has just been
  allowed an edit of that same path. Pick one by measuring what Antigravity does without the capability.
  *Done 2026-09-26: the second.* `ACPSession` notes a file the person just allowed on a runtime's
  own edit card (a diff, or an `edit` call's location), and the app's write for that file within
  60 s is served without asking again, once. The folder check still refuses a write outside reach
  first. Offering no `writeTextFile` was set aside: Antigravity would then write with its own
  tools, past the app's reach check. Tests: `ServingTests` `aWriteAlreadyAllowedOnTheRuntimesOwnCardIsNotAskedAgain`
  and `anAllowedEditOfOneFileDoesNotLetAnotherThrough`. Not re-walked live (it needs a fresh Google sign-in).
- [X] T025b [US2] **The terms line shows twice**, once under each Google choice. Show it once, below
  both (`RuntimeAccountView`: after the loop, when any shown method is in `signInNotice.methods`).
  *Done 2026-09-26, and seen on a scratch app: one terms line and link, below both Google choices.*

**Checkpoint**: US1 works with a Google sign-in (walked).

---

## Phase 4: User Story 2, sign-in sheet and a key instead (P2)

**Goal**: an unsigned start says **Needs signing in**. The sheet offers Google's methods with the
terms line. A Gemini key means no browser at all.

**Independent test**: spec US2 scenarios 1–4, with a key and without.

- [X] ~~T026~~ [US2] Authenticate a lent key before the session, in `Kit/ACP/ACPSession.swift` and
  `Kit/Daemon/DaemonCore+Runtimes.swift`.
  - When a key is lent and the runtime has `lentKeyAuthMethod`, call
    `authenticate(methodID:)` after `initialize` and before `session/new`, `load` and `resume`.
  - If it fails, the agent shows the refused-key failure.
  - A fake-runtime test checks the order of calls on the wire.
  *Removed 2026-09-26 (Google sign-in only).* Was done in the session itself: `ACPSession.launch` works out `signInMethod` from the environment the process really gets, and `initialize` authenticates when the runtime lists that method. The live test proves it against Google's server. The Mac only lends once T027 exists.
- [X] ~~T027~~ [US2] Lend the Gemini key to Antigravity on the Mac, in
  `Kit/Daemon/DaemonCore+Credentials.swift`. The key is set as `GEMINI_API_KEY` for that process
  only. If 046's Gemini kind isn't on main yet, add it:
  - kind `geminiAPIKey` in `Core/Runtimes/CredentialKind.swift`, prefixes `AIza` and `AQ.`;
  - the variable `GEMINI_API_KEY`;
  - "lent to" `[gemini, antigravity]`, so it is never lent to any other runtime;
  - the check against `generativelanguage.googleapis.com/v1beta/models?key=…` per 046's
    contract, with its tests in `Tests/Unit/CredentialKindTests.swift` and
    `CredentialCheckTests.swift`.
  *Dropped 2026-09-26: the key is not shared (D6).* Was unblocked (046 merged): `CredentialKind.geminiAPIKey` exists. Its single `runtimeID` becomes the set of runtimes it is lent to, [gemini, antigravity].
- [X] T028 [US2] Show the terms notice in `App/Sources/Runtimes/RuntimeAccountView.swift`.
  - Under the `oauth-personal` and `oauth-business` methods, show the runtime's
    `signInNotice.text` quoted, with a **Read Google's terms** link.
  - It appears only for runtimes that carry a notice.
  - Set the notice on the catalog entry (T017's file):

    > "Using third party software, tools, or services to access the Service (e.g. using
    > OpenClaw with Antigravity OAuth) is a breach of this Agreement." —
    > https://antigravity.google/terms
- [ ] T029 [US2] Make the Google sign-in work from the sheet, per T002's findings.
  - `authenticate {oauth-personal}` on a probe session.
  - If the server returns a URL and doesn't open one, open it with `NSWorkspace`, as Copilot's
    flow does.
  - A prompt waiting on sign-in goes ahead afterwards, without retyping (US1 scenario 4).
  - An abandoned or failed sign-in ends with "Sign-in did not complete" and **Try again**, never
    an endless wait. Add a timeout matching the server's listener, as measured.
- [ ] T030 [US2] Signing out and switching back. *(The persisted-key case below no longer
  applies: no key is ever used.)*
  - `logout` is offered because `auth.logout` is advertised, and after it the next start is
    **Needs signing in**.
  - The persisted-key case from T005: if the key was removed from Settings and the server
    refuses, show **Needs signing in** rather than a failure.
- [X] ~~T031~~ [US2] Settings wording in `App/Sources/Settings/ServerCredentials.swift` and
  `CredentialRow.swift`: the Gemini key row says "Used by Gemini and Antigravity", listing the
  runtimes from the kind's "lent to".
  *Dropped 2026-09-26: the key is Gemini's only.*
- [ ] T032 [US2] **Look gate and walk.**
  - Screenshot the sheet with its four methods and the terms line.
  - With Alex (his Google account): sign in with Google, the waiting prompt goes ahead, sign out,
    and **Needs signing in** again.
  - Without Alex: a key in Settings starts with no browser. Removing it shows **Needs signing in**.

---

## Phase 5: User Story 3, the app's tools and scoping (P2, ships with US1)

**Goal**: reports, questions, leases, waits and workflows work from an Antigravity agent. Its
duplicating tools are gone, and residue is named.

**Independent test**: spec US3.

- [X] T033 [US3] Check that the briefing (`Kit/ACP/Serve/Briefing.swift`) names `ask_question`
  for Antigravity through `escalationTool` and lists the residue. Add an assertion to the
  existing briefing test that covers every catalog runtime.
- [X] T034 [US3] Render the question card, per T004.
  - If a `session/request_permission` whose tool call id starts `interaction_` already reads as
    a question on the app's permission card, change nothing.
  - Otherwise add `questionToolCallPrefix: "interaction_"` to the policy as data, and have the
    card title it as a question with the options as answers. That goes in the permission-card
    view under `App/Sources/`, and the phone reads the same model.
  - Test with a fake runtime that replays T004's exact request.
- [X] T035a [US3] Auto-allow the app's own MCP tools on a runtime that asks about every MCP
  call (R6b). In `Kit/Daemon/DaemonCore+AppTools.swift` `autoAllowed`, and
  `Core/Model/PermissionRequest.swift`, treat a permission request whose
  `toolCall._meta.mcp.server` (or title prefix `<server>_`) is the app's own MCP server as the
  app's. Choose `allow_once` over `allow_always`, so nothing is persisted in the runtime's home.
  - Test: a fake runtime asks about `agents_lease_resource`, and nobody is asked.
  - Test: a request for another MCP server's tool is still put to the person.
  *Done*:
  - `AppTool.all`, `AppTool.serverName` (which `appServer` now uses) and
    `AppTool.isServedByTheApp` recognise a known app tool name only after the app's server
    prefix: `mcp__agents__`, `agents_`, `agents-` or `agents/`. A bare name never counts
    (Antigravity has its own `list_resources`).
  - `ToolCall.isAutoAllowable` includes it. `isTheApps`, which decides what the transcript
    hides, is unchanged.
  - Tests: `Tests/Integration/AppToolPermissionTests.swift` (4), including a fake Antigravity
    asking about `agents_lease_resource` mid-turn and the person never being asked.
  - Kept `autoAllowed`'s existing preference for `allow_always`: changing it would change
    Copilot too, and these are the app's own tools.
  - This also stops Copilot asking about leases, waits, events and agent tools, which spec
    023 intended ("the app answers for its own tools itself").
- [ ] T035 [US3] Live check (T024's suite).
  - The agent ends a turn with `finish_turn`, leases a resource, waits for an event, and asks a
    question that arrives as a card.
  - `start_subagent` is absent from the tool list.

---

## Phase 6: User Story 4, Antigravity on servers (P3)

**Goal**: on a bare x86_64 server with a Gemini key in Settings, a first reply in 10 minutes or
less, with the key nowhere on disk.

**Independent test**: quickstart.md §5.

- [ ] T036 [US4] Add the server's archive install to `Kit/Hosts/ToolsetInstaller.swift`.
  **Changed by T006**: a bare server can't unzip. The Mac downloads, checks and unpacks, then
  sends `tar -cz` over ssh, and the server runs only `tar -xz` (contracts/toolset-archive.md).
  - The same steps as T013, as the server script: `df` against `minFreeBytes`, `curl -fL`,
    `sha256sum -c`, `unzip -q`, the shim from `shimLines`, `ok` last, and `current`.
  - Progress lines are read into the set-up checklist.
  - Everything goes under `Toolset.serverFolder(runtimeID:)`.
- [ ] T037 [US4] `Core/Hosts/Host.swift`: `canInstall(runtime)` is false with the platform's
  `knownBroken` reason on linux-aarch64 (FR-020). The server's runtime list shows that sentence
  and offers no **Install**.
- [ ] T038 [US4] Server launch environment: `GEMINI_HOME=~/.agents-server/runtimes/antigravity/home`,
  set through T020 with the server's root, plus the lent key and `authenticate` (T026). OAuth
  methods are never offered on a server, so the sheet hides them for server projects.
- [ ] T038a [US4] Copy the Mac's Google sign-in to a server run (D8, FR-018, R6a); with no Mac
  sign-in, ask for one before starting (no key fallback, 2026-09-26). In
  `Kit/Daemon/DaemonCore+Credentials.swift` and the server connection.
  - When the Mac's `<root>/runtimes/antigravity/home` holds a Google token file (path from T006),
    write it before the run into the server's same relative path, mode 0600, over the existing
    ssh channel, never through a log.
  - The file is `<GEMINI_HOME>/antigravity-acp/acp_token.json` (T006).
  - Sign in with `oauth-personal`, the runtime's `copiedSignInAuthMethod` in
    `RuntimeLaunchCatalog`, rather than the key method. Give it 20 s. If stderr says
    `Open the following link`, kill the process: the copy was refused. Never show that link.
  - Remove the file when the last Antigravity run on that server ends, and at every connect.
  - Nothing is copied back: the file holds no access token and was unchanged by refreshes on
    both machines (R6a).
  - A server start that exits saying `compiled with avx enabled` is shown as "this server's
    processor can't run Antigravity" (T006).
  - Tests with fake ssh:
    - the file arrives before `session/new`, 0600, and is gone after the last run;
    - with no Mac sign-in the key is lent instead;
    - a refused copy says "renew on the Mac" and never opens a browser.
- [ ] T039 [US4] 043's rules for Antigravity (FR-019), in
  `Kit/Daemon/DaemonCore+Credentials.swift`:
  - the "own sign-in only" mark sends no key;
  - with no key, the app asks for it in place;
  - a refused key shows its own failure;
  - a rebuilt server is set up again on confirmation.

  Add tests beside 043's for the Gemini kind.
- [ ] T040 [US4] **Only if not yet on main**: generalise 043 per runtime, as 046/047 planned:
  - credential kinds by runtime;
  - the lendable set;
  - the own-sign-in check;
  - the server installer's folders and shim taken from the manifest.

  Claude's server suites must stay green, including `BareServerLiveTests`. If 046 or 047's server
  half has landed, merge main instead and delete this task.
- [ ] T041 [US4] Live walk with the test-servers skill: agents-bare (x86_64). Run it once with the
  Mac signed in with Google (the copied sign-in, then no token file after the run) and once with
  a key in the scratch Settings, an Antigravity server project, and a `uname -a` reply. Then run
  `scripts/leak-check.sh` for the key on the server's disk and the Mac's logs. On the devbox
  (arm64), check the known-broken sentence. Extend `Tests/Live/BareServerLiveTests.swift` with
  the Antigravity case.

---

## Phase 7: Polish and cross-cutting

- [ ] T042 [P] Check that Antigravity is offered everywhere a runtime is chosen:
  - the Mac start form and runtime menu;
  - the phone and iPad start forms (Remote reads the runtime list; build for the generic sim
    only, and the phone look is Alex's);
  - workflow steps;
  - `start_agent`.
- [ ] T043 [P] Update the docs, then run `scripts/docs-check.py`, which must pass.
  - `docs/reference/runtimes.md`: an Antigravity row covering Google's ACP server, pictures,
    sign-in, app tools, questions and residue, and how it differs from Gemini.
  - `docs/how-to/sign-a-runtime-in.md`: the Google sign-in, the terms line, and the shared key.
  - `docs/how-to/add-a-linux-server.md`: x86_64 only, and the key.
  - `docs/reference/settings.md`: the Gemini key serves both runtimes.
- [ ] T044 Check every scenario in quickstart.md against a fresh scratch root, including §6
  (`~/.gemini` byte for byte).
- [ ] T045 Update the memory spec-queue entry with 049's status, and note the terms decision
  (R10).

---

## Dependencies and execution order

- **Phase 1 (spike)**: T001 first. T002–T006 need Alex (T002) or a key (T003–T006), and can run
  in any order. T007 gates Phase 3.
- **Phase 2**: T008, T009 and T011 in parallel. Then T010 and T012.
- **US1 (Phase 3)** needs Phase 2.
  - Install (T013–T016) and the runtime (T017–T024) can proceed side by side after T010. T017
    and T018 go in one commit.
  - T025 comes last.
- **US3 (Phase 5)** needs T017/T018, and ships with US1 before Antigravity is offered.
- **US2 (Phase 4)** needs US1's runtime (T017, T020). T026 and T027 come before T029 and T030.
- **US4 (Phase 6)** needs T026/T027, and T040 if the generalisation isn't on main.
- **Polish** comes after the stories it documents.

### Parallel examples

```
Phase 2:  T008 (Toolset.swift) ‖ T011 (update-toolset.sh) ‖ T009 (tests)
US1:      T015 (installer tests) ‖ T019 (policy tests) ‖ T023 (scripts)
Polish:   T042 ‖ T043
```

## Implementation strategy

1. **Spike first** (Phase 1). Most of Phase 1 needs only a key. Ask Alex for one, or for 10
   minutes of his Google sign-in, up front.
2. **MVP = US1 + US3 with a key.** Antigravity installs from the set-up page and runs scoped
   agents on the Mac. That can merge as the first cut, because a key user is fully served.
3. **US2** adds the Google sign-in with the terms line. That is what the spec is for, so it
   should follow straight after.
4. **US4** servers last, on x86_64, after whichever lane lands the 043 generalisation.
