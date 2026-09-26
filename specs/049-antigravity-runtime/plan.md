# Implementation Plan: Google Antigravity as a Runtime

**Branch**: `agents/speckit-specify-support-antigravity` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/049-antigravity-runtime/spec.md`

> **Revised 2026-09-26 (Alex): Antigravity signs in with a Google account only.** The Gemini key
> in Settings is Gemini's and is never lent to Antigravity, and Antigravity has no key of its own
> (spec D3, D6). Servers use the Mac's Google sign-in, copied (D8), with no key fallback. So the
> lent-key sign-in (`lentKeyAuthMethod`, T026), sharing the key (T027), the Settings wording
> (T031) and the key fallback on servers are **removed**. `RuntimeLaunch.hiddenAuthMethods` takes
> the key and Agent Platform choices off the sign-in sheet. A turn that fails in words ends as
> `runtimeError`, with no refused-key case. Anything below that still says "key" for Antigravity is
> history.

## Summary

Antigravity joins `RuntimeCatalog` as `antigravity`. It is started as the app's own pinned copy
of **Google's official Antigravity ACP server** (`agy_acp_server` 1.2.1), never the `agy` CLI,
which has no ACP mode (R1). The handshake measured on 2026-09-25 (R3) shows that nearly all the
runtime side is already generic: a signed-out start is refused with `-32000`, `authenticate` and
`logout` are already in `ACPSession`, and resume, list, pictures, modes and models come from the
handshake.

What is new:

1. **A vendor-archive toolset.** Claude's, Codex's and Gemini's toolsets are Node plus an npm
   lock. Antigravity's is a zip from `dl.google.com`: a URL, a SHA-256, a size and a command for
   each platform (R2). `Toolset` gains a second shape. The Mac installer (048) and the server
   installer (043) gain a download, check and unzip path for it, with byte progress.
2. **An isolated home.** Each process gets `GEMINI_HOME=<root>/runtimes/antigravity/home`, so
   the person's `~/.gemini` is never read or written, and their hooks, skills and MCP servers
   never load (R5, D7). It also gets `AGY_ACP_DISABLE_WORKSPACE_TRUST=1` (R7).
3. **Google sign-in only.** The sheet offers the two Google methods; the key and Agent Platform
   methods the server also offers are hidden (`hiddenAuthMethods`). No key reaches the process
   (R6, revised 2026-09-26).
4. **A tool policy** through the existing `sessionMetaDenyList(["agy", "disabledTools"])`. It
   removes `start_subagent` and keeps `ask_question` as the escalation tool, which the server
   raises as a permission request whose options are the answers (R7).
5. **Turn errors that arrive as text.** The server reports a failed turn as an agent message
   starting `Agent execution error:` followed by `end_turn`. The runtime entry carries that
   prefix, and the session turns it into a failed turn. A refused key becomes 043's
   refused-key failure (R9).
6. **The terms, on the sign-in sheet.** A per-runtime `signInNotice`: a quoted line from
   Antigravity's terms and a link, shown beside the Google methods (R10, D3).
7. **Servers.** The Mac's Google sign-in is copied per run (D8). Linux x86_64 is installed on
   demand. Linux arm64 is marked known-broken until the spike shows otherwise (R12).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), like the rest of the app.

**Primary Dependencies**:
- Google's `agy_acp_server` 1.2.1, downloaded from Google at install time and never
  redistributed (R10).
- 048's `RuntimeInstaller` / `MacToolsetInstaller`.
- 043's `ToolsetInstaller`, lending and `CredentialKind`.
- The generalisations that 046 and 047 are landing (R13).

**Storage**:
- `App/Resources/toolsets/antigravity/manifest.json`: an archive manifest with no lock.
- The Mac's `<root>/tools/antigravity/<id>/`, and a server's
  `~/.agents-server/tools/antigravity/<id>/`.
- The server's own home: `<root>/runtimes/antigravity/home/` on the Mac and
  `~/.agents-server/runtimes/antigravity/home/` on a server.
- The Gemini key in the Mac's Keychain (046/043). A Google sign-in's token is a 0700 file in
  the Mac's Antigravity home (`AGY_ACP_FORCE_FILE_STORAGE=1`, D8), so it can be copied to a
  server for a run.

**Testing**:
- `swift test` in `Packages/AgentsKit`:
  - unit tests for the archive manifest, id, platform choice and known-broken;
  - `MacToolsetInstaller` against a `file://` zip, as its Node tests do;
  - the policy-totality test gaining Antigravity;
  - a fake-runtime test for `lentKeyAuthMethod` ordering and `turnErrorPrefix`.
- `scripts/acp-handshake.sh` and `scripts/runtime-tools.sh`, each gaining Antigravity.
- A live suite gated on `AGENTS_ANTIGRAVITY=1`.
- `BareServerLiveTests`, extended on agents-bare (x86_64).

**Target Platform**:
- The macOS app and agentsd (Apple silicon and Intel).
- The Linux agentsd on x86_64 servers. arm64 is known-broken until measured.
- iOS Remote only reads the runtime list.

**Project Type**: desktop app with a daemon, a bridge and a phone client.

**Performance Goals**:
- SC-001: Install to first reply in 10 minutes or less. The download is 112 MB.
- SC-002: an installed start is no more than Claude's plus 10 s. A cold session was measured at
  about 9–10 s (R8).
- SC-005: a bare server in 10 minutes or less. The download is 334 MB.

**Constraints**:
- Never touch `~/.gemini` (FR-013).
- A lent key is never on a server's disk, and a copied sign-in is there only during a run (FR-018, D8).
- Google's bytes are never in the repo or the bundle (R10).
- No runtime-id branches outside the catalogs.
- Runtime discovery must not start a 7 s handshake more often than it does today (see Phase 2).

**Scale/Scope**:
- One runtime.
- About 15 files, most of them in the installers.
- 4 docs pages.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
gates. The project's working rules stand in for it:

- **Settle the UX before depth.** The new surfaces are copies of existing ones, plus two small
  additions:
  - 048's set-up row, with a size note and byte progress;
  - the sign-in sheet with the terms notice;
  - Settings ▸ Runtime credentials, where the Gemini key says it serves both runtimes.

  One screenshot pass of the set-up row and the sign-in sheet happens early in Phase 1 and is
  the look gate.
- **The policy is total over the catalog.** Antigravity's policy lands in the same commit as its
  catalog entry.
- **No runtime-id branches.** Antigravity's differences live in the catalog entry
  (`lentKeyAuthMethod`, `turnErrorPrefix`, `signInNotice`, environment), the policy table and
  the toolset manifest.
- **Never write the person's files.** `GEMINI_HOME` is under the daemon's root.
- **Prove it running.** Walk a scratch root with a real turn using the run-app skill, and walk
  agents-bare with the test-servers skill.

Re-checked after design: holds. The deviations are in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/049-antigravity-runtime/
├── plan.md
├── research.md        # R1–R13, measured against agy_acp_server 1.2.1
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── runtime-launch.md    # command, environment, authenticate order, _meta, errors
│   └── toolset-archive.md   # the archive manifest, install steps on the Mac and servers
└── tasks.md           # /speckit-tasks
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/Runtime.swift                  # + lentKeyAuthMethod, turnErrorPrefix, signInNotice, launchEnvironment
├── Runtimes/RuntimeCatalog.swift        # + antigravity
├── Runtimes/ToolPolicyCatalog.swift     # + antigravity policy
├── Runtimes/Toolset.swift               # + Archive shape: platforms, url, sha256, size, command, knownBroken
├── Runtimes/CredentialKind.swift        # Gemini key serves [gemini, antigravity] (046's kind)
└── Hosts/Host.swift                     # canInstall(runtime) honours knownBroken
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/MacToolsetInstaller.swift   # archive path: download with progress, sha, unzip, ok, current
├── Runtimes/RuntimeInstaller.swift      # dispatch by toolset shape
├── Runtimes/RuntimeDiscovery.swift      # app-copy-only; no extra probe for a slow start
├── ACP/ACPSession.swift                 # authenticate before session/new when a key is lent; turnErrorPrefix
├── ACP/RuntimeEnvironment.swift         # per-runtime variables with <root> substituted
├── Daemon/DaemonCore+Runtimes.swift     # pass the lent key and the method
├── Daemon/DaemonCore+Credentials.swift  # lendable runtimes per kind
└── Hosts/ToolsetInstaller.swift         # the server's archive install (curl, sha256sum, unzip)
App/
├── Resources/toolsets/antigravity/manifest.json
├── Sources/Runtimes/InstallAgentsSheet.swift   # size note, byte progress
├── Sources/Runtimes/RuntimeAccountView.swift   # signInNotice under the methods
└── Sources/Settings/ServerCredentials.swift    # "Gemini key: used by Gemini and Antigravity"
scripts/update-toolset.sh                # archive mode: read the registry, fetch, hash, write the manifest
scripts/acp-handshake.sh, scripts/runtime-tools.sh   # + antigravity
docs/reference/runtimes.md, docs/how-to/sign-a-runtime-in.md,
docs/how-to/add-a-linux-server.md, docs/reference/settings.md
```

**Structure Decision**: no new modules. Antigravity is data in the runtime, policy and toolset
catalogs. The code changes are one new toolset shape and three runtime fields that other
runtimes leave empty.

## Phases

**Phase 0: Spike (needs Alex's Google sign-in, or a real Gemini key).** Run it on a scratch root
with the downloaded server and `GEMINI_HOME` in `/tmp`. Settle every **to measure** in
research.md:
- the `oauth-personal` flow (does it open a browser itself, and what arrives while it waits), and
  the Keychain service name (R5, R6);
- that the app's MCP server reaches the model (R4);
- the real tool names in a turn, whether `finish` competes with `finish_turn`, and whether a
  browser subagent appears (R7);
- how `ask_question` looks as a permission card (R7);
- what an untrusted folder does without the trust variable (R7);
- that `session/load` replays history (R3);
- the text of quota and rate-limit errors (R9);
- whether a real turn reports usage (R11);
- removing a key after `gemini-api-key` was persisted (R6).

Then Linux: x86_64 on agents-bare (install size, `--uid=`, a turn with a key, leak check) and
arm64 on the devbox (the reported crash). Findings go into research.md, and anything that
overturns a decision here is brought to Alex before Phase 2.

**Phase 1: Antigravity on the set-up page (US1, the install half).**
- The archive shape in `Toolset`.
- `update-toolset.sh --archive antigravity-acp`, which reads the registry's `agent.json`, fetches
  each platform, hashes it and writes the manifest.
- The Mac installer's archive path. It downloads with byte progress, checks the SHA-256, unzips
  into `<id>.partial`, renames to `<id>`, writes `ok` and points `current` at it. It keeps
  folders in use (047).
- The catalog entry with `usesAppCopyOnly`.
- Unit tests against a `file://` zip: a checksum mismatch, a truncated download, no space, and a
  quit mid-download.
- **Look gate**: a scratch app showing the row with its size note, **Install**, the progress and
  the tick. The screenshot goes to Alex.

**Phase 2: Antigravity agents on the Mac (US1 + US3, the MVP).**
- The policy (`disabledTools`, `escalationTool: "ask_question"`, residue).
- The launch environment (`GEMINI_HOME`, the trust variable, `GOOGLE_API_KEY` cleared).
- `lentKeyAuthMethod`, with `authenticate` called before `session/new`/`load`/`resume`.
- `turnErrorPrefix`.
- Discovery: the app's copy is **available** when its `ok` file exists. Discovery must not run a
  7–10 s handshake on every refresh: the handshake result is cached per toolset id, as the
  option cache does.
- The daemon's handshake limit is checked for Antigravity's cold start, and raised if it is
  under 30 s.
- A live test on `AGENTS_ANTIGRAVITY=1`.
- Walk: start, edit, `ls`, permission, a question card, stop, resume, a picture, and a start
  while not installed.

**Phase 3: Signing in (US2).**
- The sheet lists the four methods, with `signInNotice` (the terms line and link) under the
  Google ones.
- **Log in with Google** runs `authenticate {oauth-personal}`, opening the URL if the server
  doesn't (per the spike). A prompt waiting on sign-in goes ahead when it completes.
- An abandoned sign-in ends with **Try again**.
- Sign-out through `logout`.
- A Gemini key in Settings means no browser at all.
- The look gate is one screenshot of the sheet.

**Phase 4: Servers (US4).**
- The server's archive install in `ToolsetInstaller`: `curl`, `sha256sum`, `unzip`, `ok`,
  `current`, and a refusal when free space is under `minFreeBytes`.
- `canInstall` honours `knownBroken`.
- The Mac's Google sign-in, copied (D8, R6a): the daemon reads the 0700 token file from the
  Mac's own `GEMINI_HOME` and writes it, mode 0600, into the server's before the run, over
  the existing ssh channel. It then signs in with `oauth-personal`, and removes the file when the
  last Antigravity run there ends and again at the next connect.
- Fallback: lend the Gemini key as `GEMINI_API_KEY` with `authenticate {gemini-api-key}`. No
  browser sign-in is ever offered on a server.
- `leak-check.sh` runs after the run: no token file, and no key anywhere.
- A live walk on agents-bare: install, a turn, then `leak-check.sh` for the key.
- If 046/047 haven't generalised 043 yet, this phase does it first, and Claude's suites must stay
  green.

**Phase 5: Everywhere a runtime is chosen, and docs.**
- Check that the phone and iPad start forms, workflow steps and `start_agent` list Antigravity
  (they all read `RuntimeCatalog.builtIn`).
- Docs pages: runtimes, sign-in (with the terms note), servers (x86_64 only for now), and
  settings.
- `scripts/docs-check.py` passes.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| A second toolset shape (a vendor archive) | Google ships a signed binary zip and no npm package (R2) | forcing it into the Node/npm shape would need a fake package and still download the zip |
| `turnErrorPrefix` reads message text | the server reports a failed turn as a message plus `end_turn`, not as an error (R9) | without it, a refused key or a quota error looks like a successful turn |
| `authenticate` before `session/new` when a key is lent | the server no longer selects a method from the environment (R6) | writing `auth.type` into its settings file would mean the app editing the server's files |
| `signInNotice` on the runtime | the terms decision (R10, D3) must be in front of the person when they choose Google sign-in | a docs-only note would not be seen at the moment of choosing |
