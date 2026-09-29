# Implementation Plan: OpenCode as a Runtime

**Branch**: `agents/continue-work-supporting` | **Date**: 2026-09-28 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/049-opencode-runtime/spec.md`, revised 2026-09-28
(servers borrow the Mac's sign-in, D7), and the live probe of OpenCode 1.18.33 in
[research.md](research.md).

## Summary

OpenCode joins `RuntimeCatalog` as `opencode`, started as `<app's copy> acp`. It is the app's
own pinned copy of the release program from GitHub, never an `opencode` on the PATH (D1).

The probe showed that most of the runtime side is already generic. `initialize`, modes, models,
resume, pictures, permission asks and the app's stdio tool server all work as they are (R5, R6).
OpenCode also works signed out, with OpenCode Zen's free models (R2).

What is new:

1. **Archive toolsets grow up.** Today they are zip only, Mac only, with no baseline or musl
   builds and no size check (R10). They gain `.tar.gz`, platform variants
   (`darwin-x86_64-baseline`, `linux-x86_64[-baseline][-musl]`, `linux-aarch64[-musl]`), a
   size check, and a GitHub-releases source in `scripts/update-toolset.sh`.
2. **OpenCode's own settings for the app's agents are passed in the environment** (D4, R3).
   The policy lever `.environmentJSON(OPENCODE_CONFIG_CONTENT)` carries:
   - `autoupdate: false` and `share: "disabled"`
   - `tools: {task: false}`: removed, with no residue. `todowrite` stays, as Claude's and
     Gemini's to-do lists stay: a list inside the turn (built 2026-09-28)
   - `permission: {edit: "ask", bash: "ask", webfetch: "ask"}`

   `RuntimeLaunch.environment` adds `OPENCODE_DISABLE_AUTOUPDATE=1` and
   `OPENCODE_DISABLE_SHARE=1`, and clears `OPENCODE_AUTH_CONTENT` and
   `OPENCODE_ENABLE_QUESTION_TOOL` on the Mac.
3. **OpenCode asks before it acts.** Left to itself, OpenCode asks for nothing (R3). The app
   makes edits, commands and fetches ask, as it does for Grok. OpenCode joins 061's
   `ClientPermissionSettings`, so **Always approve** works for it as it does for Cursor and
   Grok.
4. **The sign-in command is the app's copy.** The app starts advertising
   `clientCapabilities._meta["terminal-auth"]: true`, so OpenCode sends its `auth login`
   command (R6). For an app-copy-only runtime, the daemon rewrites a terminal-auth `command`
   that is the runtime's bare executable name to its shim's full path. This is the name trap
   closed at the sign-in sheet (Story 2, AS-2).
5. **OpenCode's failure wording is mapped.**
   - `-32603 "API key is invalid."` with `errorName: APIError` becomes the refused-sign-in
     sentence.
   - `-32602 "model not found"` with `data.providerId` becomes "OpenCode isn't signed in to
     <provider>", with the sign-in sheet.
6. **A cost of zero is not a price.** A zero cost on a turn that used tokens is shown as no cost,
   not "$0", on the Mac and on the Remote (FR-008). This is generic across runtimes: no runtime
   bills a turn that used tokens at zero on purpose.
7. **Servers** (Story 5, P3):
   - The Linux archive is downloaded and checked on the Mac, then streamed over ssh as
     `tar -cz`, which is the route Antigravity's T036 planned and never built. OpenCode builds
     it, and Antigravity can use it.
   - The Mac's `auth.json` entries that do not rotate (`api`, `wellknown`) are lent per run in
     `OPENCODE_AUTH_CONTENT` through `credentials/lend`, and never written on the server (R7).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), like the rest of the app. Python and zsh for
the scripts.

**Primary Dependencies**:
- OpenCode 1.18.33 release programs from `github.com/anomalyco/opencode/releases`, downloaded at
  install time and checked against GitHub's SHA-256 digests (R1).
- 048's `RuntimeInstaller` / `MacArchiveInstaller`, and 043's `ToolsetInstaller` and lending.

**Storage**:
- The app's copy lives in `<root>/tools/opencode/<id>/`, with `current` pointing at it, as
  Antigravity's does.
- Nothing is stored of OpenCode's sign-in. The Mac's `auth.json` is read, filtered and lent per
  server run, and never copied to disk.

**Testing**: `swift test` (unit and integration with the fake launcher), the live ACP probe
`scripts/acp-handshake.sh` with `AGENTS_OPENCODE_SHIM`, run-app on a scratch root, and
test-servers against `agents-devbox`.

**Target Platform**:
- macOS arm64 and x86_64. An Intel Mac without AVX2 gets the baseline build.
- Linux servers: x86_64 and aarch64, glibc and musl.

**Performance Goals**:
- SC-002: a first reply within 5 s of a Claude start. The probe measured `session/new` at
  0.5–1.2 s and a first reply at 2.2 s.
- The install is 46 MB of download and 145 MB unpacked.

**Constraints**:
- The app never looks `opencode` up on the PATH (FR-003).
- The app never writes to `~/.config/opencode`, `~/.local/share/opencode` or `~/.opencode`
  (FR-019). OpenCode's own first-run files are OpenCode's (R4).
- No secret reaches a server's disk (FR-022).

**Scale/Scope**: one runtime. About 15 files touched in AgentsKit, the App and Remote, two
scripts and five docs.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no gates to
evaluate. The project's working rules apply instead (AGENTS.md, memory):
- walk the exact commit on a scratch app before shipping;
- never touch the real home in a probe;
- never mutate source to prove a test.

Nothing in this plan conflicts with them.

## Project Structure

### Documentation (this feature)

```text
specs/049-opencode-runtime/
├── spec.md          # revised 2026-09-28
├── research.md      # R1–R10: live probe + code survey
├── plan.md          # this file
├── data-model.md    # manifest variants, policy, launch, lent sign-in
├── quickstart.md    # the walks that prove it
└── contracts/
    ├── opencode-launch.md       # what the app passes to every OpenCode process
    └── archive-manifest-v2.md   # tar.gz, variants, size
```

### Source Code (repository root)

```text
App/Resources/toolsets/opencode/manifest.json            # new: archive manifest, 9 platforms
Packages/AgentsKit/Sources/AgentsKitCore/
├── Runtimes/RuntimeCatalog.swift        # + opencode (appended to builtIn)
├── Runtimes/ToolPolicyCatalog.swift     # + opencode policy (same order)
├── Runtimes/RuntimeLaunch.swift         # + opencode launch environment
├── Runtimes/ArchiveToolset.swift        # format (zip|tarGz), variants, platform chooser
├── ACP/ACPTypes.swift                   # _meta["terminal-auth"] in client capabilities
├── Model/ClientPermissionSettings.swift # + opencode
└── Model/Usage.swift / Agent.swift      # zero cost on a used turn = no cost
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/MacArchiveInstaller.swift   # tar.gz, size check, variant choice (AVX2)
├── Daemon/DaemonCore+Runtimes.swift     # rewrite terminal-auth command to the shim
├── Daemon/DaemonCore+Commands.swift     # OpenCode's refused-key and unknown-provider errors
├── Daemon/DaemonCore+Credentials.swift  # opencode lent sign-in → OPENCODE_AUTH_CONTENT (servers)
├── Hosts/ServerArchiveInstaller.swift   # new: Mac downloads, tar -cz over ssh, ok last
└── Projects/PersonalDotAgents*.swift    # + opencode rule (no links; stdio MCP)
App/Sources/
├── Hosts/HostSet.swift, SignInRelays.swift   # opencode offered on servers; lend its sign-in
├── Hosts/OpenCodeFileSignIn.swift            # new: read + filter ~/.local/share/opencode/auth.json
├── Settings/AgentRuntimesSettingsView.swift  # 061 row for OpenCode
└── Chat/ContextMeter.swift                   # (+ Remote/Sources/Chat/RemoteChatView.swift) zero cost
scripts/update-toolset.sh                     # --archive-github <runtime> <owner/repo> <tag>
scripts/acp-handshake.sh, scripts/runtime-tools.sh   # + opencode
Packages/AgentsKit/Tests/AgentsKitTests/…     # ArchiveToolsetTests, new OpenCode tests
```

**Structure Decision**: this is the existing app. OpenCode is catalog data, one policy, one
launch entry and an archive manifest. The generic pieces it needs are the archive variants and
formats, the server archive install, the terminal-auth rewrite and zero cost. They go where
their kind already lives, so that Antigravity (servers) and any later single-program runtime
(050 Goose) inherit them.

## Phases

### Phase 0: Research *(done)*

See [research.md](research.md). Every open question in the spec's Assumptions is answered:

| Spec question | Answer |
|---|---|
| Does the app advertise terminal-auth? | No; add `_meta["terminal-auth"]` (R6, R10) |
| Where does "not signed in" arrive? | It doesn't: the model is not in the menu; picking one by id fails at `set_config_option` (R6) |
| Does OpenCode need a provider? | No: Zen free models (R2) |
| Which tools can inline config remove? | `task`, `todowrite`, fully (R3) |
| Is `autoupdate: false` enough? | Used together with `OPENCODE_DISABLE_AUTOUPDATE` (R3) |
| Gatekeeper? | Ad-hoc signed; no prompt when downloaded by the app (R1) |
| How does a server run get a sign-in? | `OPENCODE_AUTH_CONTENT`, in memory (R7) |
| Personal skills and instructions? | Read natively; no links (R8) |
| Move to a worktree? | Keeps the old folder; not carried (R9) |

### Phase 1: Archive toolsets, generalised (foundation)

- `ArchiveToolset.Platform` gains `format` (derived from the URL suffix: `.zip` or `.tar.gz`).
- The manifest's platform keys may carry variant suffixes. `ArchiveToolset.platformKey(for:)`
  chooses the most specific key that is present:
  - **Mac**: `darwin-x86_64-baseline` when `sysctl hw.optional.avx2_0` is 0.
  - **Linux**: `-musl` when `/lib/ld-musl-*` exists, and `-baseline` when `/proc/cpuinfo`
    lacks `avx2`. The server-side probe reports both facts.
  - Otherwise it falls back to the plain key.
- `MacArchiveInstaller` unpacks `.tar.gz` with `/usr/bin/tar -xzf`, verifies the downloaded
  `size`, and leaves the quarantine attribute unset.
- `scripts/update-toolset.sh --archive-github opencode anomalyco/opencode v1.18.33` writes the
  manifest from the release's `digest` and `size` fields. It allows `github.com` release URLs
  only, as the `dl.google.com` rule does.
- `ArchiveToolsetTests` no longer pins `["antigravity"]`. New tests cover variant choice,
  tar.gz, and a size mismatch refused.

### Phase 2: OpenCode on the Mac (Stories 1, 2, 4, P1/P2)

- `RuntimeCatalog.opencode`:
  - `executable: "opencode"` (the shim's name), `arguments: ["acp"]`
  - `install: .toolset(runtimeID: "opencode")`, `usesAppCopyOnly: true`
  - `installPage`: opencode.ai/docs
  - The header comment records the name trap.
- `ToolPolicyCatalog.opencode` holds the removed tools, the environment lever (contract
  [opencode-launch.md](contracts/opencode-launch.md)) and `escalationTool: nil`, so questions go
  to `ask_form`.
- `RuntimeLaunchCatalog.opencode` holds the static environment.
- `PersonalDotAgents` gets a rule for OpenCode: no skills or instructions links,
  `takesStdioServers: true`.
- `carriesConversationAcrossFolders` is left out (R9).
- 061: `ClientPermissionSettings` gains `opencode`, with a row in Settings ▸ Agent Runtimes.
- Zero cost is shown as no cost, on the Mac meter and the Remote.
- Tests:
  - the every-runtime loops;
  - the policy's environment JSON, byte for byte;
  - a fake `opencode` placed first on the PATH is never run (Story 2's test, on the fake
    launcher);
  - a zero cost is not banked.

### Phase 3: Signing in on the Mac (Story 3, P2)

- `ACP.ClientCapabilities` sends `_meta: {"terminal-auth": true}` beside `jetbrains.air`.
  Re-run `scripts/acp-handshake.sh` for all eight runtimes to confirm that no other runtime
  changes its methods.
- Daemon: for `usesAppCopyOnly` runtimes, a terminal-auth `command` equal to
  `runtime.executable` becomes the shim's absolute path.
- The sheet has no **Sign out**. It names `auth logout`, as it does for Cursor.
- `signInReason` also matches OpenCode's `APIError` "API key is invalid". A `set_config_option`
  failure that has `data.providerId` becomes a sentence naming the provider, with the sheet.
- Tests use recorded JSON from the probe, in `Tests/Fixtures/opencode/`.

### Phase 4: Servers (Story 5, P3)

- `ServerArchiveInstaller`:
  1. The window's Mac side downloads the Linux asset for the server's reported platform key and
     checks it.
  2. It streams `tar -cz` over the existing ssh into `<server root>/tools/opencode/.part-<id>`.
  3. The server unpacks it, writes the shim, writes `ok` last and moves it into place.

  It is used by OpenCode, and by Antigravity when its T036 is picked up.
- `OpenCodeFileSignIn` (App):
  - reads `~/.local/share/opencode/auth.json` on the Mac (`XDG_DATA_HOME` respected);
  - keeps the `api` and `wellknown` entries only;
  - sends them with `credentials/lend` as `OPENCODE_AUTH_CONTENT`, for OpenCode runs on that
    server only.

  "Own sign-in only" servers are lent nothing. Filtered-out entries are named in the sheet.
- `HostSet.serverRuntimes` offers OpenCode when the Mac has the lendable sign-ins, and when it
  has none, because the Zen models need nothing.
- test-servers walk on `agents-devbox` (x86_64 glibc) and a musl check (Alpine container).
  Afterwards, `grep -r` for the key on the box finds nothing.

### Phase 5: Docs

The five docs the spec lists, README's runtime count, and `scripts/runtime-tools.sh`.
`docs-check.py` must pass.

## Defaults this plan takes

P1 and P2 confirmed by Alex on 2026-09-28. P3 is the spec's D7 default.

- **P1. OpenCode asks before edits, commands and fetches**, whatever the person's own OpenCode
  config says. **Always approve** in Settings (061) turns the asks off. Without this, the app's
  OpenCode agents would act unasked, unlike every other runtime.
- **P2. A zero cost on a turn that used tokens shows as no cost, for every runtime.**
- **P3. Only non-rotating sign-ins are lent** (D7 default, from the spec).

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| Archive variants (baseline, musl) | Intel Macs without AVX2 and Alpine servers get a program that runs | One build per architecture crashes with an illegal instruction on those machines |
| Server archive install via Mac + `tar -cz` | FR-021; servers may lack `unzip` and outbound GitHub | Running `curl` on the server needs outbound access and a second trust path for the digest |
| terminal-auth rewrite | Stops the sheet handing over a bare `opencode` (name trap) | Hard-coding a command per runtime drifts from what the runtime says (FR-010) |
